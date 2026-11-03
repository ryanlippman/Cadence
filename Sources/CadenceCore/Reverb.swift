import Foundation

/// Compact Freeverb-style stereo reverb. Intentionally light: short-ish room, damped highs.
public final class Reverb {
    private struct Comb {
        var buf: UnsafeMutablePointer<Float>
        var size: Int
        var idx = 0
        var store: Float = 0
    }
    private struct Allpass {
        var buf: UnsafeMutablePointer<Float>
        var size: Int
        var idx = 0
    }
    private var combsL: [Comb] = [], combsR: [Comb] = []
    private var apL: [Allpass] = [], apR: [Allpass] = []
    private let feedback: Float
    private let damp: Float

    public init(sampleRate: Double, roomSize: Float = 0.80, damping: Float = 0.40) {
        let scale = sampleRate / 44100.0
        let combT = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let apT = [556, 441, 341, 225]
        let spread = 23
        func mk(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n); return p
        }
        for t in combT {
            let a = max(8, Int(Double(t) * scale)), b = max(8, Int(Double(t + spread) * scale))
            combsL.append(Comb(buf: mk(a), size: a)); combsR.append(Comb(buf: mk(b), size: b))
        }
        for t in apT {
            let a = max(8, Int(Double(t) * scale)), b = max(8, Int(Double(t + spread) * scale))
            apL.append(Allpass(buf: mk(a), size: a)); apR.append(Allpass(buf: mk(b), size: b))
        }
        feedback = roomSize
        damp = damping
    }

    deinit {
        for c in combsL + combsR { c.buf.deallocate() }
        for a in apL + apR { a.buf.deallocate() }
    }

    /// Processes in place: out = dry*(1-wet*0) + wet-signal*wet. `wet` is the wet gain (dry stays at unity).
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, wet: Float) {
        let fb = feedback, d = damp, d1 = 1 - damp
        for n in 0..<frames {
            let input = (left[n] + right[n]) * 0.015
            var oL: Float = 0, oR: Float = 0
            for i in 0..<combsL.count {
                let yl = combsL[i].buf[combsL[i].idx]
                combsL[i].store = yl * d1 + combsL[i].store * d
                combsL[i].buf[combsL[i].idx] = input + combsL[i].store * fb
                combsL[i].idx += 1; if combsL[i].idx >= combsL[i].size { combsL[i].idx = 0 }
                oL += yl
                let yr = combsR[i].buf[combsR[i].idx]
                combsR[i].store = yr * d1 + combsR[i].store * d
                combsR[i].buf[combsR[i].idx] = input + combsR[i].store * fb
                combsR[i].idx += 1; if combsR[i].idx >= combsR[i].size { combsR[i].idx = 0 }
                oR += yr
            }
            for i in 0..<apL.count {
                let bl = apL[i].buf[apL[i].idx]
                apL[i].buf[apL[i].idx] = oL + bl * 0.5
                oL = bl - oL
                apL[i].idx += 1; if apL[i].idx >= apL[i].size { apL[i].idx = 0 }
                let br = apR[i].buf[apR[i].idx]
                apR[i].buf[apR[i].idx] = oR + br * 0.5
                oR = br - oR
                apR[i].idx += 1; if apR[i].idx >= apR[i].size { apR[i].idx = 0 }
            }
            left[n] += oL * wet
            right[n] += oR * wet
        }
    }
}
