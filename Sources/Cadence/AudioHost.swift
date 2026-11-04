import Foundation
import AVFoundation
import CadenceCore

/// Owns the AVAudioEngine. The synth always runs at its fixed internal rate (48 kHz); the main mixer
/// converts to whatever the output device uses. When the device changes (headphones plugged in,
/// AirPods connected, sample-rate change) the engine is simply restarted: the composer and all musical
/// state live in `SynthCore`, so the piece continues where it was.
final class AudioHost {
    let engine = AVAudioEngine()
    let core: SynthCore
    private var source: AVAudioSourceNode!
    private let topUpQueue = DispatchQueue(label: "cadence.compose", qos: .userInitiated)
    private var topUpTimer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private(set) var wantsRunning = false
    var onError: ((String) -> Void)?

    init(bank: SampleBank, params: EngineParams) {
        core = SynthCore(bank: bank, style: params.style, mode: params.mode)
        core.setParams(params)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2)!
        let core = self.core
        source = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core.render(left: l, right: r, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.recoverFromConfigurationChange() }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    private func recoverFromConfigurationChange() {
        guard wantsRunning else { return }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do { try engine.start() } catch { onError?("Audio output changed and could not restart: \(error.localizedDescription)") }
    }

    func start() throws {
        wantsRunning = true
        core.topUp()
        if !engine.isRunning { try engine.start() }
        topUpTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: topUpQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.core.topUp() }
        t.resume()
        topUpTimer = t
    }

    func pause() {
        wantsRunning = false
        topUpTimer?.cancel(); topUpTimer = nil
        engine.pause()
    }
}
