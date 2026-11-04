import Foundation
import AVFoundation

/// Plain-old-data view of a decoded sample, safe to copy on the audio thread (no reference counting).
public struct ZoneData {
    public let left: UnsafeMutablePointer<Int16>
    public let right: UnsafeMutablePointer<Int16>
    public let frames: Int
    public let sampleRate: Double
    public let centerMidi: Int
    public let layerVelocity: Int
    /// RMS of the first 0.3 s, used to normalise layers so loudness follows velocity smoothly.
    public let attackRMS: Float
    /// First frame of the attack (leading silence trimmed so every note speaks on time).
    public let startOffset: Int
}

/// Multi-velocity piano sample set (Salamander Grand Piano subset, CC BY 3.0) plus release noises.
/// All lookups the audio thread needs are precomputed into flat tables at load time.
public final class SampleBank {
    /// Nominal MIDI velocity of each bundled layer (original Salamander layer numbers 3, 5, 7, 9).
    public static let layerVelocities = [3: 36, 5: 45, 7: 54, 9: 68]
    static let maxLayers = 4

    public let zones: [ZoneData]
    public let releaseZones: [ZoneData]
    public private(set) var centers: [Int] = []
    /// For MIDI note m: nearest centre and the centre on the other side (for pseudo round-robin).
    var nearest = [Int](repeating: 0, count: 128)
    var alternate = [Int](repeating: -1, count: 128)
    /// layerTable[center * maxLayers + k] = zone index of k-th layer (ascending velocity), -1 if none.
    var layerTable = [Int](repeating: -1, count: 128 * 4)
    var layerCount = [Int](repeating: 0, count: 128)
    /// releaseTable[midi] = release-zone index nearest to that key.
    var releaseTable = [Int](repeating: -1, count: 128)

    public init(zones: [ZoneData], releaseZones: [ZoneData] = []) {
        self.zones = zones
        self.releaseZones = releaseZones
        buildTables()
    }

    deinit {
        for z in zones + releaseZones { z.left.deallocate(); z.right.deallocate() }
    }

    public var residentBytes: Int { (zones + releaseZones).reduce(0) { $0 + $1.frames * 4 } }

    public static func resourceDirectory() -> URL? {
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("Cadence_CadenceCore.bundle/Samples")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let u = Bundle.module.resourceURL?.appendingPathComponent("Samples")
        return u.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    public static func loadBundled() throws -> SampleBank {
        guard let dir = resourceDirectory() else { throw SampleError.missing("Samples directory not found") }
        return try load(directory: dir)
    }

    public static func load(directory: URL) throws -> SampleBank {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["caf", "m4a", "wav"].contains($0.pathExtension) }
        guard !files.isEmpty else { throw SampleError.missing("No samples in \(directory.path)") }
        var results = [(ZoneData, Bool)?](repeating: nil, count: files.count)
        let lock = NSLock()
        var firstError: Error?
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            do {
                let z = try decode(url: files[i])
                lock.lock(); results[i] = z; lock.unlock()
            } catch {
                lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
            }
        }
        if let e = firstError { throw e }
        let all = results.compactMap { $0 }
        return SampleBank(zones: all.filter { !$0.1 }.map { $0.0 }, releaseZones: all.filter { $0.1 }.map { $0.0 })
    }

    static func pitch(_ s: Substring) -> Int? {
        var p = String(s)
        guard !p.isEmpty else { return nil }
        let letter = p.removeFirst()
        var sharp = false
        if p.hasPrefix("s") { sharp = true; p.removeFirst() }
        guard let oct = Int(p) else { return nil }
        let base: Int
        switch letter {
        case "C": base = 0; case "D": base = 2; case "E": base = 4; case "F": base = 5
        case "G": base = 7; case "A": base = 9; case "B": base = 11
        default: return nil
        }
        return base + (sharp ? 1 : 0) + (oct + 1) * 12
    }

    /// "Ds4_v7" → (63, 7, false); "rel_Ds4" → (63, 0, true)
    static func parseName(_ name: String) -> (midi: Int, layer: Int, release: Bool)? {
        let parts = name.split(separator: "_")
        guard parts.count == 2 else { return nil }
        if parts[0] == "rel" { return pitch(parts[1]).map { ($0, 0, true) } }
        guard parts[1].hasPrefix("v"), let layer = Int(parts[1].dropFirst()), let m = pitch(parts[0]) else { return nil }
        return (m, layer, false)
    }

    static func decode(url: URL) throws -> (ZoneData, Bool) {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let (midi, layer, isRelease) = parseName(stem) else { throw SampleError.badName(stem) }
        let vel = isRelease ? 0 : (layerVelocities[layer] ?? 0)
        if !isRelease && vel == 0 { throw SampleError.badName(stem) }
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SampleError.missing("buffer alloc failed")
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        guard let ch = buf.floatChannelData else { throw SampleError.missing("no float data") }
        let l = UnsafeMutablePointer<Int16>.allocate(capacity: n + 4)
        let r = UnsafeMutablePointer<Int16>.allocate(capacity: n + 4)
        let c1 = fmt.channelCount > 1 ? ch[1] : ch[0]
        for i in 0..<n {
            l[i] = Int16(max(-1, min(1, ch[0][i])) * 32767)
            r[i] = Int16(max(-1, min(1, c1[i])) * 32767)
        }
        for i in n..<(n + 4) { l[i] = 0; r[i] = 0 }
        // onset: first sample above −54 dBFS, minus 1 ms of pre-roll (release noises play from 0)
        var onset = 0
        if !isRelease {
            let thr: Int16 = 65
            while onset < n && abs(Int(l[onset])) < Int(thr) && abs(Int(r[onset])) < Int(thr) { onset += 1 }
            onset = max(0, min(onset - Int(fmt.sampleRate * 0.001), Int(fmt.sampleRate * 0.05)))
        }
        let m = min(n - onset, Int(fmt.sampleRate * 0.3))
        var acc = 0.0
        for i in onset..<(onset + m) { let a = Double(l[i]) / 32768, b = Double(r[i]) / 32768; acc += a * a + b * b }
        let rms = Float(max(1e-4, (acc / Double(2 * max(1, m))).squareRoot()))
        return (ZoneData(left: l, right: r, frames: n, sampleRate: fmt.sampleRate, centerMidi: midi,
                         layerVelocity: vel, attackRMS: rms, startOffset: onset), isRelease)
    }

    private func buildTables() {
        var byCenter: [Int: [Int]] = [:]
        for (i, z) in zones.enumerated() { byCenter[z.centerMidi, default: []].append(i) }
        centers = byCenter.keys.sorted()
        for (c, idx) in byCenter {
            let sorted = idx.sorted { zones[$0].layerVelocity < zones[$1].layerVelocity }.prefix(SampleBank.maxLayers)
            for (k, zi) in sorted.enumerated() { layerTable[c * SampleBank.maxLayers + k] = zi }
            layerCount[c] = sorted.count
        }
        guard !centers.isEmpty else { return }
        for m in 0..<128 {
            let near = centers.min { abs($0 - m) < abs($1 - m) }!
            nearest[m] = near
            let other = centers.filter { $0 != near && abs($0 - m) <= 2 && ($0 - m).signum() != (near - m).signum() }
            alternate[m] = other.first ?? -1
        }
        if !releaseZones.isEmpty {
            for m in 0..<128 {
                releaseTable[m] = releaseZones.indices.min { abs(releaseZones[$0].centerMidi - m) < abs(releaseZones[$1].centerMidi - m) }!
            }
        }
    }
}

public enum SampleError: Error, CustomStringConvertible {
    case missing(String)
    case badName(String)
    public var description: String {
        switch self {
        case .missing(let s): return "Sample error: \(s)"
        case .badName(let s): return "Unrecognised sample name: \(s)"
        }
    }
}
