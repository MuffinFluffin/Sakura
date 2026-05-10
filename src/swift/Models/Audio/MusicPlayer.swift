// SPDX-License-Identifier: GPL-3.0+

import Foundation
import AVFoundation
import Observation
import SwiftUI

@Observable
@MainActor
final class MusicPlayer: NSObject {
    static let shared = MusicPlayer()

    enum LoopMode: String, Codable { case off, all, one }

    /// The full ordered playlist the mini-bar cycles through.
    private(set) var playlist: [MusicTrack] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    /// The last known progress 0…1 of the currently loaded track.
    private(set) var progress: Double = 0
    /// Seconds.
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var loopMode: LoopMode = .all {
        didSet { UserDefaults.standard.set(loopMode.rawValue, forKey: Keys.loopMode) }
    }

    var shuffleEnabled: Bool = false {
        didSet { UserDefaults.standard.set(shuffleEnabled, forKey: Keys.shuffleEnabled) }
    }

    var volume: Float = 0.7 {
        didSet {
            UserDefaults.standard.set(volume, forKey: Keys.volume)
            player?.volume = volume
        }
    }

    var currentTrack: MusicTrack? {
        guard playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }

    // sticky flag: user-driven paused-or-playing preference. cleared only
    // when the user taps the mini-bar. honoured on app launch, except we
    // never start playback on launch. resume only when the library first
    // appears AND this flag is true.
    private(set) var userWantsPlaying: Bool = false

    // MARK: - Private state

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var didConfigureSession = false
    @ObservationIgnored private var pausedByGame = false
    @ObservationIgnored private var fadeTimer: Timer?
    private let fadeDuration: TimeInterval = 0.35

    // MARK: - Init

    private override init() {
        super.init()

        if UserDefaults.standard.object(forKey: Keys.userWantsPlaying) != nil {
            userWantsPlaying = UserDefaults.standard.bool(forKey: Keys.userWantsPlaying)
        } else {
            userWantsPlaying = true
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.loopMode),
           let mode = LoopMode(rawValue: raw) {
            loopMode = mode
        }
        if UserDefaults.standard.object(forKey: Keys.shuffleEnabled) != nil {
            shuffleEnabled = UserDefaults.standard.bool(forKey: Keys.shuffleEnabled)
        }
        if UserDefaults.standard.object(forKey: Keys.volume) != nil {
            volume = UserDefaults.standard.float(forKey: Keys.volume)
        }

        refreshPlaylist()

        if shuffleEnabled, playlist.count > 1 {
            currentIndex = Int.random(in: playlist.indices)
        } else if let slug = UserDefaults.standard.string(forKey: Keys.lastSlug),
                  let idx = playlist.firstIndex(where: { $0.slug == slug }) {
            currentIndex = idx
        }
        loadCurrent()
    }

    // MARK: - Playlist management

    func refreshPlaylist() {
        let builtins = MusicCatalog.downloadedBuiltinTracks()
        let user = MusicCatalog.importedUserTracks()
        playlist = builtins + user

        if !playlist.isEmpty {
            currentIndex = min(currentIndex, playlist.count - 1)
        } else {
            currentIndex = 0
        }
    }

    // MARK: - Transport

    // load (without starting) the current track. safe to call with an
    // empty playlist, the player is simply cleared.
    private func loadCurrent() {
        stopProgressTimer()
        player?.stop()
        player = nil
        progress = 0
        currentTime = 0
        duration = 0

        guard let track = currentTrack else {
            isPlaying = false
            return
        }

        configureAudioSessionIfNeeded()

        do {
            let p = try AVAudioPlayer(contentsOf: track.localURL)
            p.delegate = self
            p.volume = volume
            p.prepareToPlay()
            player = p
            duration = p.duration
            UserDefaults.standard.set(track.slug, forKey: Keys.lastSlug)
        } catch {
            SakuraLogUnified("Music", "Warning", "Failed to load \(track.title): \(error.localizedDescription)")
            player = nil
        }
    }

    func play() {
        configureAudioSessionIfNeeded()
        guard player != nil else {
            loadCurrent()
            guard player != nil else { return }
            play()
            return
        }
        player?.volume = 0
        player?.play()
        fadeIn()
        isPlaying = true
        userWantsPlaying = true
        UserDefaults.standard.set(true, forKey: Keys.userWantsPlaying)
        startProgressTimer()
        SakuraNotificationCenter.shared.post(
            .music(trackTitle: currentTrack?.title ?? "Music")
        )
    }

    func pause() {
        fadeOut { [weak self] in
            guard let self else { return }
            self.player?.pause()
            self.isPlaying = false
            self.userWantsPlaying = false
            UserDefaults.standard.set(false, forKey: Keys.userWantsPlaying)
            self.stopProgressTimer()
        }
    }

    /// Mini-bar tap target. Single entry point for user-driven toggling.
    func toggleFromUser() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = isPlaying
        cancelFade()
        currentIndex = nextTrackIndex()
        loadCurrent()
        if wasPlaying { play() }
    }

    func previous() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = isPlaying
        cancelFade()
        currentIndex = (currentIndex - 1 + playlist.count) % playlist.count
        loadCurrent()
        if wasPlaying { play() }
    }

    private func nextTrackIndex() -> Int {
        guard playlist.indices.contains(currentIndex) else { return playlist.startIndex }
        guard shuffleEnabled, playlist.count > 1 else { return (currentIndex + 1) % playlist.count }
        var nextIndex = currentIndex
        while nextIndex == currentIndex {
            nextIndex = Int.random(in: playlist.indices)
        }
        return nextIndex
    }

    // jump directly to a specific track (e.g. from a tap in the track
    // list). preserves playing state so running playback continues with
    // the new track.
    func select(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let wasPlaying = isPlaying
        currentIndex = index
        loadCurrent()
        if wasPlaying { play() }
    }

    func toggleLoop() {
        switch loopMode {
        case .off: loopMode = .all
        case .all: loopMode = .one
        case .one: loopMode = .off
        }
    }

    /// Seek to a 0…1 progress value.
    func seek(toProgress p: Double) {
        guard let pl = player else { return }
        let t = max(0, min(pl.duration, pl.duration * p))
        pl.currentTime = t
        currentTime = t
        progress = pl.duration > 0 ? t / pl.duration : 0
    }

    // MARK: - Game coordination

    // called when the emulator starts. pauses music while preserving the
    // sticky user-wants-playing flag so we can resume on return. also
    // hands the shared audio session back so external apps (Spotify,
    // Apple Music, etc.) regain full audio priority during gameplay.
    func pauseForGame() {
        if isPlaying {
            pausedByGame = true
            stopProgressTimer()
            fadeOut { [weak self] in
                guard let self else { return }
                self.player?.pause()
                self.isPlaying = false
                AudioSession.shared.suspendForGame()
            }
        } else {
            AudioSession.shared.suspendForGame()
        }
    }

    /// Called when returning to Library. Resumes only if the user's sticky
    /// state was "playing" when the game was entered.
    func resumeAfterGame() {
        AudioSession.shared.resumeForUIAudio()
        guard pausedByGame, userWantsPlaying else { return }
        pausedByGame = false
        player?.volume = 0
        player?.play()
        isPlaying = true
        fadeIn()
        startProgressTimer()
    }

    // MARK: - App lifecycle hook

    /// Called from `LibraryShell.onAppear`. Starts playback if the
    /// user hasn't explicitly paused (sticky flag). On first launch the
    /// default for the flag is `true`, so music auto-plays immediately.
    func autoResumeIfStickyAndLibraryVisible() {
        guard onboardingPlayer == nil else { return }
        guard userWantsPlaying, !isPlaying, !playlist.isEmpty else { return }
        play()
    }

    // MARK: - Fade

    @ObservationIgnored private var fadeStep = 0
    @ObservationIgnored private var fadeCompletion: (() -> Void)?

    private func fadeIn() {
        cancelFade()
        let target = volume
        player?.volume = 0
        fadeStep = 0
        let total = 14
        let interval = fadeDuration / Double(total)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fadeStep += 1
                let frac = Float(self.fadeStep) / Float(total)
                self.player?.volume = target * frac
                if self.fadeStep >= total {
                    self.player?.volume = target
                    self.cancelFade()
                }
            }
        }
    }

    private func fadeOut(completion: @escaping () -> Void) {
        cancelFade()
        guard let pl = player, pl.volume > 0 else {
            completion()
            return
        }
        let startVol = pl.volume
        fadeStep = 0
        fadeCompletion = completion
        let total = 14
        let interval = fadeDuration / Double(total)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fadeStep += 1
                let frac = Float(self.fadeStep) / Float(total)
                self.player?.volume = startVol * (1 - frac)
                if self.fadeStep >= total {
                    self.player?.volume = 0
                    let cb = self.fadeCompletion
                    self.fadeCompletion = nil
                    self.cancelFade()
                    cb?()
                }
            }
        }
    }

    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    // MARK: - Audio session

    private func configureAudioSessionIfNeeded() {
        if AudioSession.shared.ensureActiveForUIAudio() {
            didConfigureSession = true
        }
    }

    // MARK: - Progress timer

    private func startProgressTimer() {
        stopProgressTimer()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickProgress() }
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tickProgress() {
        guard let pl = player else { return }
        currentTime = pl.currentTime
        duration = pl.duration
        progress = pl.duration > 0 ? pl.currentTime / pl.duration : 0
    }

    // MARK: - Onboarding music

    // separate player for onboarding. loops featured default track
    // independently of the main playlist. torn down when onboarding finishes.
    @ObservationIgnored private var onboardingPlayer: AVAudioPlayer?
    @ObservationIgnored private var onboardingMusicBootTask: Task<Void, Never>?

    // stops menu music without clearing the sticky play preference, otherwise
    // library auto-resume would stack a second onboarding track.
    private func silenceMainPlayerForOnboarding() {
        cancelFade()
        stopProgressTimer()
        player?.pause()
        player?.volume = volume
        isPlaying = false
    }

    // downloads the Butterflow track if needed, then starts loop-playing it.
    // safe to call multiple times, no-ops if already playing.
    func startOnboardingMusic() {
        silenceMainPlayerForOnboarding()
        guard onboardingPlayer == nil else { return }
        let track = MusicCatalog.featured.first!
        if track.isDownloaded {
            beginOnboardingPlayback(url: track.localURL)
            return
        }
        guard onboardingMusicBootTask == nil else { return }
        onboardingMusicBootTask = Task { @MainActor in
            defer { onboardingMusicBootTask = nil }
            do {
                let url = try await MusicCatalog.download(track)
                guard !Task.isCancelled else { return }
                guard onboardingPlayer == nil else { return }
                beginOnboardingPlayback(url: url)
            } catch {
                SakuraLogUnified("Music", "Warning", "Failed to download onboarding track: \(error.localizedDescription)")
            }
        }
    }

    private func beginOnboardingPlayback(url: URL) {
        configureAudioSessionIfNeeded()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = volume
            p.play()
            onboardingPlayer = p
        } catch {
            SakuraLogUnified("Music", "Warning", "Onboarding player failed: \(error.localizedDescription)")
        }
    }

    func setOnboardingLoopPlayback(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        silenceMainPlayerForOnboarding()
        onboardingMusicBootTask?.cancel()
        onboardingMusicBootTask = nil
        onboardingPlayer?.stop()
        onboardingPlayer = nil
        beginOnboardingPlayback(url: url)
    }

    /// Stop onboarding music. Called when onboarding finishes.
    func stopOnboardingMusic() {
        onboardingMusicBootTask?.cancel()
        onboardingMusicBootTask = nil
        onboardingPlayer?.stop()
        onboardingPlayer = nil
    }

    // MARK: - Storage

    private enum Keys {
        static let loopMode = "sakura.music.loopMode"
        static let volume = "sakura.music.volume"
        static let lastSlug = "sakura.music.lastSlug"
        static let userWantsPlaying = "sakura.music.userWantsPlaying"
        static let shuffleEnabled = "sakura.music.shuffleEnabled"
    }
}

extension MusicPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.loopMode {
            case .one:
                self.player?.currentTime = 0
                self.player?.play()
            case .all:
                self.next()
            case .off:
                self.isPlaying = false
                self.userWantsPlaying = false
                UserDefaults.standard.set(false, forKey: "sakura.music.userWantsPlaying")
                self.stopProgressTimer()
            }
        }
    }
}
