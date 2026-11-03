import Foundation

public enum WAV {
    /// Writes 16-bit PCM stereo WAV.
    public static func write(left: [Float], right: [Float], sampleRate: Int, to url: URL) throws {
        let n = min(left.count, right.count)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 4))
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 4))
        var pcm = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            pcm[2 * i] = Int16(max(-1, min(1, left[i])) * 32767)
            pcm[2 * i + 1] = Int16(max(-1, min(1, right[i])) * 32767)
        }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }
}
