import Foundation
import AVFoundation
import MediaPlayer
import IOKit.pwr_mgt
import CadenceCore

@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    @Published var settings: UserSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            host?.core.setParams(engineParams)
            if settings.timerMinutes != oldValue.timerMinutes { restartTimer() }
            if settings.mode != oldValue.mode || settings.styleRaw != oldValue.styleRaw { updateNowPlaying() }
        }
    }
    enum State { case loading, idle, playing, stopping }
    @Published private(set) var state: State = .loading
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var sessionProgress: Double = 0
    @Published private(set) var status = EngineStatus()
    @Published private(set) var errorMessage: String?

    var isPlaying: Bool { state == .playing || state == .stopping }
    var isLoading: Bool { state == .loading }

    private var host: AudioHost?
    private var bank: SampleBank?
    private var poll: Timer?
    private var sessionStart = Date()
    private var sessionEnd: Date?
    private var fadingOut = false
    /// When the engine session (and its arc) began.
    private var engineSessionStart = Date()
    @Published private(set) var arcPhase: ArcPhase = .sustaining

    /// Settings plus session timing, as the engine needs them.
    private var engineParams: EngineParams {
        var p = settings.engineParams
        if let end = sessionEnd, isPlaying { p.sessionSeconds = end.timeIntervalSince(engineSessionStart) }
        return p
    }
    private var assertionID: IOPMAssertionID = 0
    private(set) var maxPeakSeen: Float = 0

    private init() {
        settings = UserSettings.load()
        Task.detached(priority: .userInitiated) {
            do {
                let b = try SampleBank.loadBundled()
                await MainActor.run {
                    self.bank = b
                    self.state = .idle
                    self.setupRemoteCommands()
                }
            } catch {
                await MainActor.run { self.errorMessage = "Could not load the piano: \(error)"; self.state = .idle }
            }
        }
    }

    /// Cheap, lock-protected read for the visualiser (called every frame while visible).
    func meters() -> EngineMeters? { host?.core.meters }

    // MARK: transport

    func toggle() {
        switch state {
        case .idle: start()
        case .playing: stop()
        case .stopping: finishStop()
        case .loading: break
        }
    }

    func start() {
        guard state == .idle, let bank else { return }
        errorMessage = nil
        if host == nil {
            let h = AudioHost(bank: bank, params: engineParams)
            h.onError = { [weak self] msg in Task { @MainActor in self?.errorMessage = msg } }
            host = h
        }
        guard let host else { return }
        host.core.setParams(engineParams)
        host.core.resetPlayback()
        engineSessionStart = Date()
        host.core.startSession(fadeInSeconds: 3)
        do { try host.start() } catch {
            errorMessage = "Audio output failed to start: \(error.localizedDescription)"
            return
        }
        state = .playing
        fadingOut = false
        sessionStart = Date()
        restartTimer()
        host.core.setParams(engineParams)
        preventSleep(true)
        updateNowPlaying()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Gentle stop: 1.5 s fade, then the engine pauses. The composition resumes where it left off.
    func stop() {
        guard state == .playing, let core = host?.core else { return }
        state = .stopping
        core.beginFadeOut(seconds: 1.5)
        updateNowPlaying()
    }

    private func finishStop() {
        poll?.invalidate(); poll = nil
        host?.pause()
        state = .idle
        fadingOut = false
        remaining = nil
        sessionEnd = nil
        sessionProgress = 0
        preventSleep(false)
        updateNowPlaying()
    }

    func selectMode(_ m: FocusMode) { settings.mode = m }
    func selectStyle(_ s: CompositionStyle?) { settings.style = s }

    // MARK: session timer

    private func restartTimer() {
        guard isPlaying else { return }
        if settings.timerMinutes > 0 {
            sessionStart = Date()
            sessionEnd = sessionStart.addingTimeInterval(Double(settings.timerMinutes) * 60)
        } else {
            sessionEnd = nil; remaining = nil; sessionProgress = 0
        }
        host?.core.setParams(engineParams)
        if fadingOut || state == .stopping {      // extending a fading session brings the music back
            host?.core.resume(fadeInSeconds: 3)
            fadingOut = false
            state = .playing
            updateNowPlaying()
        }
    }

    private func tick() {
        guard isPlaying, let core = host?.core else { return }
        let m = core.meters
        maxPeakSeen = max(maxPeakSeen, m.peak)
        let st = core.currentStatus
        if st != status { status = st }
        if m.arcPhase != arcPhase { arcPhase = m.arcPhase }
        if let end = sessionEnd {
            let left = end.timeIntervalSinceNow
            remaining = max(0, left)
            sessionProgress = min(1, Date().timeIntervalSince(sessionStart) / end.timeIntervalSince(sessionStart))
            if left <= settings.fadeOutSeconds, !fadingOut, state == .playing {
                fadingOut = true
                core.beginFadeOut(seconds: max(1, left))
            }
        }
        if m.fadeFinished && (state == .stopping || fadingOut) { finishStop() }
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
        for cmd in [c.nextTrackCommand, c.previousTrackCommand, c.seekForwardCommand, c.seekBackwardCommand,
                    c.changePlaybackPositionCommand] { cmd.isEnabled = false }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if state == .playing {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: "\(settings.mode.title) · \(settings.style?.title ?? "Varied")",
                MPMediaItemPropertyArtist: "Cadence",
                MPMediaItemPropertyAlbumTitle: "Generated piano",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            ]
            center.playbackState = .playing
        } else {
            center.playbackState = state == .idle ? .stopped : .paused
        }
    }
}
