import Foundation
import AVFoundation
import MediaPlayer
import IOKit.pwr_mgt
import Combine
import CadenceCore

@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    @Published var settings: UserSettings { didSet { settings.save(); pushParams(); if settings.timerMinutes != oldValue.timerMinutes { restartTimer() } } }
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = true
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var nowPlayingText = ""
    @Published private(set) var errorMessage: String?
    /// Peak of the last rendered block (for self-test and a subtle meter).
    @Published private(set) var level: Float = 0

    private var host: AudioHost?
    private var bank: SampleBank?
    private var poll: Timer?
    private var sessionStart = Date()
    private var sessionEnd: Date?
    private var fadingOut = false
    private var userStopping = false
    private var assertionID: IOPMAssertionID = 0
    private var maxPeakSeen: Float = 0
    private var configObserver: NSObjectProtocol?

    private init() {
        settings = UserSettings.load()
        Task.detached(priority: .userInitiated) {
            do {
                let b = try SampleBank.loadBundled()
                await MainActor.run { self.bank = b; self.isLoading = false; self.setupRemoteCommands() }
            } catch {
                await MainActor.run { self.errorMessage = "\(error)"; self.isLoading = false }
            }
        }
    }

    var peakSeen: Float { maxPeakSeen }

    // MARK: transport

    func toggle() {
        if !isPlaying { start() }
        else if userStopping { finishStop() }
        else { stop() }
    }

    func start() {
        guard !isPlaying, let bank else { return }
        errorMessage = nil
        do {
            if host == nil {
                host = AudioHost(bank: bank)
                configObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: host?.engine, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleConfigChange() }
                }
            }
            guard let host else { return }
            host.core.setParams(settings.engineParams)
            host.core.resetPlayback()
            host.core.startSession(fadeInSeconds: 2.5)
            host.core.topUp()
            try host.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }
        isPlaying = true
        userStopping = false
        fadingOut = false
        sessionStart = Date()
        restartTimer()
        preventSleep(true)
        updateNowPlaying()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Gentle user stop: short fade, then pause.
    func stop() {
        guard isPlaying, let core = host?.core else { return }
        userStopping = true
        core.beginFadeOut(seconds: 1.5)
        updateNowPlaying()
    }

    private func finishStop() {
        poll?.invalidate(); poll = nil
        host?.core.resetPlayback()
        host?.pause()
        isPlaying = false
        userStopping = false
        fadingOut = false
        remaining = nil
        sessionEnd = nil
        level = 0
        preventSleep(false)
        updateNowPlaying()
    }

    private func handleConfigChange() {
        guard let host, isPlaying else { return }
        host.rebuild(params: settings.engineParams)
        host.core.startSession(fadeInSeconds: 1)
        host.core.topUp()
        try? host.start()
    }

    // MARK: session timer

    private func restartTimer() {
        guard isPlaying else { return }
        if settings.timerMinutes > 0 {
            sessionEnd = Date().addingTimeInterval(Double(settings.timerMinutes) * 60)
            // extending the timer mid-fade brings the music back
            if fadingOut, let core = host?.core { core.startSession(fadeInSeconds: 3); fadingOut = false }
        } else {
            sessionEnd = nil; remaining = nil
            if fadingOut, let core = host?.core { core.startSession(fadeInSeconds: 3); fadingOut = false }
        }
    }

    static let fadeOutSeconds = 25.0

    private func tick() {
        guard isPlaying, let core = host?.core else { return }
        maxPeakSeen = max(maxPeakSeen, core.outputPeak)
        level = core.outputPeak
        if !core.currentKeyName.isEmpty {
            nowPlayingText = "\(core.currentKeyName) · \(Int(core.currentTempo.rounded())) BPM"
        }
        if let end = sessionEnd {
            let left = end.timeIntervalSinceNow
            remaining = max(0, left)
            if left <= PlayerController.fadeOutSeconds, !fadingOut, !userStopping {
                fadingOut = true
                core.beginFadeOut(seconds: max(1, left))
            }
        }
        if core.fadeFinished { finishStop() }
    }

    // MARK: params

    private func pushParams() { host?.core.setParams(settings.engineParams) }

    func selectMode(_ m: FocusMode) {
        settings.mode = m
        updateNowPlaying()
    }

    // MARK: system integration

    private func preventSleep(_ on: Bool) {
        if on, assertionID == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Cadence is playing" as CFString, &assertionID)
        } else if !on, assertionID != 0 {
            IOPMAssertionRelease(assertionID); assertionID = 0
        }
    }

    private var remoteSetUp = false
    private func setupRemoteCommands() {
        guard !remoteSetUp else { return }
        remoteSetUp = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.start() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.stop() }; return .success }
        c.stopCommand.addTarget { [weak self] _ in Task { @MainActor in self?.stop() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        for cmd in [c.nextTrackCommand, c.previousTrackCommand, c.seekForwardCommand, c.seekBackwardCommand] { cmd.isEnabled = false }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if isPlaying {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Cadence · \(settings.mode.title)",
                MPMediaItemPropertyArtist: "Generated piano",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: userStopping ? 0.0 : 1.0,
            ]
            center.playbackState = userStopping ? .paused : .playing
        } else {
            center.playbackState = .paused
        }
    }
}
