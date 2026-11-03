import Foundation
import AVFoundation
import CadenceCore

/// Owns the AVAudioEngine and wires SynthCore into it through an AVAudioSourceNode.
final class AudioHost {
    let engine = AVAudioEngine()
    private(set) var core: SynthCore
    private var source: AVAudioSourceNode?
    private let bank: SampleBank
    private let topUpQueue = DispatchQueue(label: "cadence.topup", qos: .userInitiated)
    private var topUpTimer: DispatchSourceTimer?

    init(bank: SampleBank) {
        self.bank = bank
        let rate = AudioHost.hardwareRate(engine)
        core = SynthCore(bank: bank, sampleRate: rate)
        attach()
    }

    static func hardwareRate(_ engine: AVAudioEngine) -> Double {
        let r = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return r > 8000 ? r : 48000
    }

    private func attach() {
        let rate = core.sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let core = self.core
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core.render(left: l, right: r, frames: Int(frames))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    /// Re-create the chain after an output device/sample-rate change.
    func rebuild(params: EngineParams) {
        engine.stop()
        if let s = source { engine.detach(s) }
        core = SynthCore(bank: bank, sampleRate: AudioHost.hardwareRate(engine))
        core.setParams(params)
        attach()
    }

    func start() throws {
        if !engine.isRunning { try engine.start() }
        topUpTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: topUpQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.core.topUp() }
        t.resume()
        topUpTimer = t
    }

    func pause() {
        topUpTimer?.cancel(); topUpTimer = nil
        engine.pause()
    }
}
