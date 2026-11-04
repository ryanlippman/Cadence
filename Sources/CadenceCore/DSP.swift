import Foundation

@inline(__always) func allocZeroed(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

/// 8-line feedback delay network reverb with input diffusion, early reflections, frequency-dependent
/// decay (one-pole damping per line), gently modulated delays (no metallic ringing) and a smoothly
/// adjustable RT60. Stereo in, stereo wet out (added to the input buffers).
public final class FDNReverb {
    static let n = 8
    private let sr: Double
    private var lines: [UnsafeMutablePointer<Float>] = []
    private var sizes: [Int] = []
    private var delays: [Double] = []
    private var writeIdx = [Int](repeating: 0, count: 8)
    private var lp = [Float](repeating: 0, count: 8)
    private var gains = [Float](repeating: 0, count: 8)
    private var damp: Float = 0.3
    private var t60: Double = 2.4
    private var t60Target: Double = 2.4
    // predelay + early reflections
    private let pre: UnsafeMutablePointer<Float>
    private let preSize: Int
    private var preIdx = 0
    private let preDelay: Int
    private let erTaps: [(Int, Float, Bool)]
    // input diffusion
    private var apBuf: [UnsafeMutablePointer<Float>] = []
    private var apSize: [Int] = []
    private var apIdx = [Int](repeating: 0, count: 4)
    private var modPhase = 0.0
    private let modInc: Double
    private var denormal: Float = 1e-20
    private let scratch = allocZeroed(8)

    public init(sampleRate: Double, t60: Double = 2.4) {
        sr = sampleRate
        let ms: [Double] = [31.7, 37.9, 41.3, 47.9, 53.1, 59.3, 67.1, 73.7]
        for m in ms {
            let d = m * 0.001 * sampleRate
            let size = Int(d) + 32
            lines.append(allocZeroed(size)); sizes.append(size); delays.append(d)
        }
        preSize = Int(0.08 * sampleRate)
        pre = allocZeroed(preSize)
        preDelay = Int(0.018 * sampleRate)
        erTaps = [(7.1, 0.32, true), (11.3, 0.28, false), (16.9, 0.22, true), (23.3, 0.2, false),
                  (29.6, 0.15, true), (37.4, 0.12, false), (44.0, 0.09, true)].map { (Int($0.0 * 0.001 * sampleRate), Float($0.1), $0.2) }
        for m in [4.7, 3.6, 12.7, 9.3] {
            let s = Int(m * 0.001 * sampleRate)
            apBuf.append(allocZeroed(s)); apSize.append(s)
        }
        modInc = 2 * .pi * 0.11 / sampleRate
        self.t60 = t60; t60Target = t60
        updateGains()
    }

    deinit {
        lines.forEach { $0.deallocate() }
        apBuf.forEach { $0.deallocate() }
        pre.deallocate()
        scratch.deallocate()
    }

    public func setDecay(_ seconds: Double) { t60Target = max(0.3, min(8, seconds)) }

    private func updateGains() {
        for i in 0..<FDNReverb.n { gains[i] = Float(pow(10, -3 * delays[i] / (t60 * sr))) }
        damp = Float(0.25 + 0.1 * min(1, t60 / 4))
    }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, wet: Float) {
        if abs(t60 - t60Target) > 0.001 {
            t60 += (t60Target - t60) * min(1, Double(frames) / (sr * 0.5))
            updateGains()
        }
        let n = FDNReverb.n
        let o = scratch
        for f in 0..<frames {
            denormal = -denormal
            let input = (left[f] + right[f]) * 0.5
            pre[preIdx] = input
            // early reflections
            var erL: Float = 0, erR: Float = 0
            for (d, g, toLeft) in erTaps {
                var k = preIdx - d; if k < 0 { k += preSize }
                if toLeft { erL += pre[k] * g } else { erR += pre[k] * g }
            }
            var k0 = preIdx - preDelay; if k0 < 0 { k0 += preSize }
            var s = pre[k0]
            preIdx += 1; if preIdx >= preSize { preIdx = 0 }
            // input diffusion (series allpasses)
            for a in 0..<4 {
                let b = apBuf[a][apIdx[a]]
                let y = b - 0.6 * s
                apBuf[a][apIdx[a]] = s + 0.6 * y
                s = y
                apIdx[a] += 1; if apIdx[a] >= apSize[a] { apIdx[a] = 0 }
            }
            // read lines (lines 1 and 5 slowly modulated, linear interpolation)
            modPhase += modInc; if modPhase > 2 * .pi { modPhase -= 2 * .pi }
            let mod = sin(modPhase)
            @inline(__always) func read(_ i: Int) -> Float {
                var d = delays[i]
                if i == 1 { d += 5 * mod } else if i == 5 { d -= 4 * mod }
                var rp = Double(writeIdx[i]) - d
                if rp < 0 { rp += Double(sizes[i]) }
                let ri = Int(rp), fr = Float(rp - Double(ri))
                let a = lines[i][ri], b = lines[i][ri + 1 < sizes[i] ? ri + 1 : 0]
                return a + (b - a) * fr
            }
            for i in 0..<n { o[i] = read(i) }
            let o0 = o[0], o1 = o[1], o2 = o[2], o3 = o[3], o4 = o[4], o5 = o[5], o6 = o[6], o7 = o[7]
            // damping + decay
            for i in 0..<n {
                lp[i] = o[i] * (1 - damp) + lp[i] * damp
                o[i] = lp[i] * gains[i]
            }
            // Householder feedback
            let sum = (o[0] + o[1] + o[2] + o[3] + o[4] + o[5] + o[6] + o[7]) * (2.0 / 8.0)
            for i in 0..<n {
                lines[i][writeIdx[i]] = o[i] - sum + s * (i % 2 == 0 ? 0.5 : -0.5) + denormal
                writeIdx[i] += 1; if writeIdx[i] >= sizes[i] { writeIdx[i] = 0 }
            }
            let wl = (o0 + o2 - o4 + o6 - o1 * 0.5) * 0.4 + erL
            let wr = (o1 + o3 - o5 + o7 - o2 * 0.5) * 0.4 + erR
            left[f] += wl * wet
            right[f] += wr * wet
        }
    }
}

/// Sympathetic string resonance: with the sustain pedal down every damper is lifted, so undamped
/// strings ring in sympathy with whatever is played. Modelled as 24 tuned, damped comb "strings"
/// (C2–B3) fed by the dry piano; their feedback is high while the pedal is down and collapses
/// (dampers fall) when it is lifted.
public final class SympatheticResonance {
    private let count = 24
    private var bufs: [UnsafeMutablePointer<Float>] = []
    private var sizes: [Int] = []
    private var delay: [Double] = []
    private var idx: [Int]
    private var lp: [Float]
    private var gUp: [Float] = [], gDown: [Float] = []
    private var pedal: Float = 0
    private let pedalCoef: Float
    public var inputGain: Float = 0.0025
    public var outputGain: Float = 0.6

    public init(sampleRate: Double) {
        idx = [Int](repeating: 0, count: count)
        lp = [Float](repeating: 0, count: count)
        for k in 0..<count {
            let f = 440 * pow(2, Double(36 + k - 69) / 12)
            let period = sampleRate / f
            let d = period - 0.5          // compensate the loop low-pass's phase delay
            let size = Int(d) + 4
            bufs.append(allocZeroed(size)); sizes.append(size); delay.append(d)
            gDown.append(Float(pow(10, -3 * period / (4.0 * sampleRate))))   // pedal down: T60 ≈ 4 s
            gUp.append(Float(pow(10, -3 * period / (0.15 * sampleRate))))    // dampers on: ≈ 0.15 s
        }
        pedalCoef = Float(1 - exp(-1 / (sampleRate * 0.03)))
    }
    deinit { bufs.forEach { $0.deallocate() } }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, pedalDown: Bool) {
        let target: Float = pedalDown ? 1 : 0
        for f in 0..<frames {
            pedal += (target - pedal) * pedalCoef
            let input = (left[f] + right[f]) * 0.5 * inputGain
            var oL: Float = 0, oR: Float = 0
            for k in 0..<count {
                var rp = Double(idx[k]) - delay[k]
                if rp < 0 { rp += Double(sizes[k]) }
                let ri = Int(rp), fr = Float(rp - Double(ri))
                let a = bufs[k][ri], b = bufs[k][ri + 1 < sizes[k] ? ri + 1 : 0]
                let y = a + (b - a) * fr
                lp[k] = y * 0.6 + lp[k] * 0.4
                let g = gUp[k] + (gDown[k] - gUp[k]) * pedal
                bufs[k][idx[k]] = input + lp[k] * g
                idx[k] += 1; if idx[k] >= sizes[k] { idx[k] = 0 }
                if k & 1 == 0 { oL += y } else { oR += y }
            }
            left[f] += oL * outputGain
            right[f] += oR * outputGain
        }
    }
}

/// Transparent look-ahead peak limiter (2 ms look-ahead, 150 ms release, −1 dBFS ceiling).
/// Gain reduction completes before a peak arrives, so the final safety clip never engages and no
/// discontinuity is created. At Cadence's normal levels it is inactive.
public final class Limiter {
    private let look: Int
    private let dl: UnsafeMutablePointer<Float>
    private let dr: UnsafeMutablePointer<Float>
    private let req: UnsafeMutablePointer<Float>
    private var idx = 0
    private var gain: Float = 1
    private let attack: Float
    private let release: Float
    public var ceiling: Float = 0.89
    public private(set) var minGain: Float = 1

    public init(sampleRate: Double) {
        look = max(8, Int(sampleRate * 0.002))
        dl = allocZeroed(look); dr = allocZeroed(look)
        req = .allocate(capacity: look); req.initialize(repeating: 1, count: look)
        attack = Float(exp(-1 / (Double(look) / 5)))
        release = Float(exp(-1 / (sampleRate * 0.15)))
    }
    deinit { dl.deallocate(); dr.deallocate(); req.deallocate() }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        minGain = 1
        for f in 0..<frames {
            let inL = left[f], inR = right[f]
            let peak = max(abs(inL), abs(inR))
            req[idx] = peak > ceiling ? ceiling / peak : 1
            // the smallest gain needed by anything inside the look-ahead window
            var target: Float = 1
            for k in 0..<look { target = min(target, req[k]) }
            gain = target < gain ? gain * attack + target * (1 - attack) : gain * release + target * (1 - release)
            let outL = dl[idx], outR = dr[idx]
            dl[idx] = inL; dr[idx] = inR
            idx += 1; if idx >= look { idx = 0 }
            left[f] = max(-0.995, min(0.995, outL * gain))
            right[f] = max(-0.995, min(0.995, outR * gain))
            minGain = min(minGain, gain)
        }
    }
}

/// Headphone externalisation: a gentle crossfeed (each ear hears a delayed, low-passed copy of the other
/// channel, as with loudspeakers in a room) plus a few sparse early reflections, so the piano sits out
/// in front of the listener instead of inside the head. On loudspeakers the effect is subtle and harmless.
/// `amount` (0...1) is smoothed per sample, so toggling never clicks.
public final class Externalizer {
    private let sampleRate: Double
    private let size = 4096
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var w = 0
    private var lpL: Float = 0, lpR: Float = 0
    private let lpCoef: Float
    private let cross: Int
    private let taps: [(dl: Int, dr: Int, g: Float)]
    private var amountS: Float = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        bufL = allocZeroed(4096); bufR = allocZeroed(4096)
        lpCoef = Float(1 - exp(-2 * Double.pi * 700 / sampleRate))
        cross = Int(0.00028 * sampleRate)   // interaural delay ≈ 0.28 ms
        // early reflections, slightly different per ear (ms), decaying
        let ms: [(Double, Double, Float)] = [(7.1, 8.3, 0.16), (11.9, 10.7, 0.12), (17.3, 19.1, 0.09), (23.9, 22.4, 0.06)]
        taps = ms.map { (Int($0.0 * sampleRate / 1000), Int($0.1 * sampleRate / 1000), $0.2) }
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, amount: Float) {
        if amount == 0 && amountS < 1e-5 {
            // keep the delay lines current so switching on starts cleanly
            for i in 0..<frames { bufL[w] = left[i]; bufR[w] = right[i]; w = (w + 1) & (size - 1) }
            amountS = 0
            return
        }
        let mask = size - 1
        let crossGain: Float = 0.32
        // keep the overall level steady: crossfeed and reflections add energy
        let norm: Float = 1 / (1 + crossGain * 0.45 + 0.12)
        for i in 0..<frames {
            amountS += (amount - amountS) * 0.0005
            let xl = left[i], xr = right[i]
            bufL[w] = xl; bufR[w] = xr
            let dL = bufL[(w - cross) & mask], dR = bufR[(w - cross) & mask]
            lpL += (dL - lpL) * lpCoef
            lpR += (dR - lpR) * lpCoef
            var yl = xl + crossGain * lpR
            var yr = xr + crossGain * lpL
            for t in taps {
                // reflections arrive from the side opposite their ear's delay, mixed mono-ish
                let m = 0.5 * (bufL[(w - t.dl) & mask] + bufR[(w - t.dl) & mask])
                let n = 0.5 * (bufL[(w - t.dr) & mask] + bufR[(w - t.dr) & mask])
                yl += t.g * m; yr += t.g * n
            }
            yl *= norm; yr *= norm
            left[i] = xl + (yl - xl) * amountS
            right[i] = xr + (yr - xr) * amountS
            w = (w + 1) & mask
        }
    }
}
