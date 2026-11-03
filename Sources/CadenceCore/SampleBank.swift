import Foundation
import AVFoundation

/// A single decoded piano sample (Int16 stereo, to keep resident memory modest).
public final class SampleZone {
    public let centerMidi: Int
    public let layerVelocity: Int
    public let frames: Int
    public let sampleRate: Double
    /// RMS of the first 0.3 s (used to normalise layers so loudness follows velocity smoothly).
    public var attackRMS: Float = 0.05
    public let left: UnsafeMutablePointer<Int16>
    public let right: UnsafeMutablePointer<Int16>

    init(centerMidi: Int, layerVelocity: Int, frames: Int, sampleRate: Double,
         left: UnsafeMutablePointer<Int16>, right: UnsafeMutablePointer<Int16>) {
        self.centerMidi = centerMidi
        self.layerVelocity = layerVelocity
        self.frames = frames
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// Multi-velocity piano sample set (Salamander Grand Piano subset, CC-BY 3.0).
public final class SampleBank {
    /// Nominal MIDI velocity of each recorded layer file (v4, v7, v10 of the 16 originals).
    public static let layerVelocities = [4: 40, 7: 53, 10: 76]

    public private(set) var zones: [SampleZone] = []
    /// zoneIndex[centerMidi] -> zone indices ordered by layer velocity ascending
    private var byCenter: [Int: [Int]] = [:]
    public private(set) var centers: [Int] = []

    public init(zones: [SampleZone]) {
        self.zones = zones
        index()
    }

    public static func resourceDirectory() -> URL? {
        // In a packaged .app the SwiftPM resource bundle lives in Contents/Resources.
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("Cadence_CadenceCore.bundle/Samples")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let candidates = [Bundle.module.resourceURL?.appendingPathComponent("Samples")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func loadBundled() throws -> SampleBank {
        guard let dir = resourceDirectory() else { throw SampleError.missing("Samples directory not found") }
        return try load(directory: dir)
    }

    public static func load(directory: URL) throws -> SampleBank {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4a" }
        guard !files.isEmpty else { throw SampleError.missing("No samples in \(directory.path)") }
        var results = [SampleZone?](repeating: nil, count: files.count)
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
        return SampleBank(zones: results.compactMap { $0 })
    }

    static func parseName(_ name: String) -> (midi: Int, layer: Int)? {
        // e.g. "Ds4_v7"
        let parts = name.split(separator: "_")
        guard parts.count == 2, parts[1].hasPrefix("v"), let layer = Int(parts[1].dropFirst()) else { return nil }
        var p = String(parts[0])
        let letter = p.removeFirst()
        var sharp = false
        if p.hasPrefix("s") { sharp = true; p.removeFirst() }
        guard let oct = Int(p) else { return nil }
        let base: Int
        switch letter {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        return (base + (sharp ? 1 : 0) + (oct + 1) * 12, layer)
    }

    static func decode(url: URL) throws -> SampleZone {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let (midi, layer) = parseName(stem), let vel = layerVelocities[layer] else {
            throw SampleError.badName(stem)
        }
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
            throw SampleError.missing("buffer alloc failed")
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        guard let ch = buf.floatChannelData else { throw SampleError.missing("no float data") }
        let l = UnsafeMutablePointer<Int16>.allocate(capacity: n)
        let r = UnsafeMutablePointer<Int16>.allocate(capacity: n)
        let c1 = fmt.channelCount > 1 ? ch[1] : ch[0]
        for i in 0..<n {
            l[i] = Int16(max(-1, min(1, ch[0][i])) * 32767)
            r[i] = Int16(max(-1, min(1, c1[i])) * 32767)
        }
        let zone = SampleZone(centerMidi: midi, layerVelocity: vel, frames: n, sampleRate: fmt.sampleRate, left: l, right: r)
        let m = min(n, Int(fmt.sampleRate * 0.3))
        var acc: Double = 0
        for i in 0..<m { let a = Double(l[i]) / 32768, b = Double(r[i]) / 32768; acc += a * a + b * b }
        zone.attackRMS = Float(max(1e-4, (acc / Double(2 * max(1, m))).squareRoot()))
        return zone
    }

    private func index() {
        byCenter = [:]
        for (i, z) in zones.enumerated() { byCenter[z.centerMidi, default: []].append(i) }
        for k in byCenter.keys { byCenter[k]!.sort { zones[$0].layerVelocity < zones[$1].layerVelocity } }
        centers = byCenter.keys.sorted()
    }

    /// Picks the nearest recorded pitch and the two velocity layers bracketing `velocity`,
    /// with a crossfade weight. Returns (zoneLo, zoneHi, weightHi).
    func select(midi: Int, velocity: Int) -> (center: Int, lo: Int, hi: Int, wHi: Float)? {
        guard let center = centers.min(by: { abs($0 - midi) < abs($1 - midi) }),
              let idx = byCenter[center], !idx.isEmpty else { return nil }
        let vels = idx.map { zones[$0].layerVelocity }
        let v = velocity
        if v <= vels[0] { return (center, idx[0], idx[0], 0) }
        if v >= vels[vels.count - 1] { return (center, idx[idx.count - 1], idx[idx.count - 1], 0) }
        for k in 0..<(idx.count - 1) where v >= vels[k] && v <= vels[k + 1] {
            let w = Float(v - vels[k]) / Float(vels[k + 1] - vels[k])
            return (center, idx[k], idx[k + 1], w)
        }
        return (center, idx[0], idx[0], 0)
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
