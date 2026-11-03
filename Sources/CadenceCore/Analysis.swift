import Foundation

/// Offline audio analysis used by the test-suite and the `cadence-analyze` tool.
public enum AudioAnalysis {
    public static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

    public static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return (acc / Double(x.count)).squareRoot()
    }
    public static func rms(_ x: [Float]) -> Double { rms(x[...]) }
    public static func peak(_ x: [Float]) -> Double { Double(x.reduce(0) { max($0, abs($1)) }) }

    /// Short-term RMS (dBFS) over `window` seconds with `hop` seconds spacing.
    public static func shortTermDB(_ x: [Float], sampleRate: Double, window: Double = 0.4, hop: Double = 0.1) -> [Double] {
        let w = Int(window * sampleRate), h = Int(hop * sampleRate)
        var out: [Double] = []
        var i = 0
        while i + w <= x.count { out.append(db(rms(x[i..<(i + w)]))); i += h }
        return out
    }

    public static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
    }

    /// Counts isolated single-sample discontinuities ("clicks"): samples whose second difference
    /// is far larger than the local second-difference energy around them. Piano hammer transients
    /// are spread over several milliseconds and do not trigger this.
    public static func clickCount(_ x: [Float], ratio: Double = 10, floor: Double = 2e-3) -> (count: Int, worst: Double) {
        guard x.count > 300 else { return (0, 0) }
        var d2 = [Double](repeating: 0, count: x.count)
        for n in 2..<x.count { d2[n] = Double(x[n]) - 2 * Double(x[n - 1]) + Double(x[n - 2]) }
        var sq = [Double](repeating: 0, count: x.count + 1)
        for n in 0..<x.count { sq[n + 1] = sq[n] + d2[n] * d2[n] }
        let r = 96
        var count = 0, worst = 0.0, lastHit = -10_000
        for n in (r + 2)..<(x.count - r - 2) {
            let a = abs(d2[n])
            if a < floor { continue }
            let total = sq[n + r + 1] - sq[n - r]
            let center = sq[n + 3] - sq[n - 2]
            let local = ((total - center) / Double(2 * r - 4)).squareRoot()
            let score = a / max(local, 1e-9)
            if score > ratio {
                if n - lastHit > 200 { count += 1 }
                lastHit = n
                worst = max(worst, score)
            }
        }
        return (count, worst)
    }

    /// RMS envelope sampled at `envRate` Hz.
    public static func envelope(_ x: [Float], sampleRate: Double, envRate: Double = 500) -> [Double] {
        let hop = Int(sampleRate / envRate)
        var env: [Double] = []
        env.reserveCapacity(x.count / hop)
        var i = 0
        while i + hop <= x.count { env.append(rms(x[i..<(i + hop)])); i += hop }
        return env
    }

    /// Hann-windowed single-bin DFT magnitude of the (mean-removed) envelope at `f` Hz.
    public static func envelopeMagnitude(_ e: [Double], envRate: Double, at f: Double) -> Double {
        let n = e.count
        guard n > 1 else { return 0 }
        let mean = e.reduce(0, +) / Double(n)
        var re = 0.0, im = 0.0, wsum = 0.0
        // recurrence for cos/sin to keep this fast
        let dw = 2 * Double.pi * f / envRate
        let c = cos(dw), s = sin(dw)
        var cr = 1.0, ci = 0.0
        for k in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(k) / Double(n - 1))
            let v = (e[k] - mean) * w
            re += v * cr; im -= v * ci; wsum += w
            let ncr = cr * c - ci * s
            ci = cr * s + ci * c; cr = ncr
        }
        return (re * re + im * im).squareRoot() * 2 / wsum
    }

    public struct Peak { public var freq: Double; public var magnitude: Double; public var median: Double
        public var prominence: Double { magnitude / max(median, 1e-12) } }

    public static func envelopePeak(_ e: [Double], envRate: Double, band: ClosedRange<Double>, step: Double = 0.05) -> Peak {
        var best = (0.0, -1.0)
        var mags: [Double] = []
        var f = band.lowerBound
        while f <= band.upperBound + 1e-9 {
            let m = envelopeMagnitude(e, envRate: envRate, at: f)
            mags.append(m)
            if m > best.1 { best = (f, m) }
            f += step
        }
        return Peak(freq: best.0, magnitude: best.1, median: percentile(mags, 0.5))
    }

    /// Spectral centroid (Hz) of a segment using a direct DFT over a coarse frequency grid.
    public static func spectralCentroid(_ x: ArraySlice<Float>, sampleRate: Double) -> Double {
        let n = min(4096, x.count)
        guard n > 64 else { return 0 }
        let seg = Array(x.prefix(n))
        var num = 0.0, den = 0.0
        var f = 50.0
        while f < 12000 {
            let w = 2 * Double.pi * f / sampleRate
            var re = 0.0, im = 0.0
            for k in 0..<n { re += Double(seg[k]) * cos(w * Double(k)); im += Double(seg[k]) * sin(w * Double(k)) }
            let m = (re * re + im * im).squareRoot()
            num += f * m; den += m
            f *= 1.12
        }
        return den > 0 ? num / den : 0
    }

    public static func hasNonFinite(_ x: [Float]) -> Bool { x.contains { !$0.isFinite } }
}
