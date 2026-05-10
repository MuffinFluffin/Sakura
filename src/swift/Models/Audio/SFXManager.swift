// SFXManager.swift: UI sound effects manager.
//
// plays short audio cues for navigation events (confirm, back, toggle,
// navigate). SFX files download from GitHub (MuffinFluffin/Shared-Assets)
// on first boot and cache in Documents/sfx/. downloads run silently in
// the background, no opt-in required.
//
// SPDX-License-Identifier: GPL-3.0+

import AVFoundation
import UIKit

@Observable
@MainActor
final class SFXManager {
    static let shared = SFXManager()

    // master on/off, stored in UserDefaults via the theme manager.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "sakura.sfx.enabled") }
    }

    // volume 0..1, separate from music volume.
    var volume: Float {
        didSet {
            let clamped = max(0, min(1, volume))
            if clamped != volume { volume = clamped }
            UserDefaults.standard.set(clamped, forKey: "sakura.sfx.volume")
        }
    }

    // whether the initial download has completed or was already cached.
    var isReady: Bool = false

    // set while a game is running. while true, play(_:) is a no-op and any
    // currently-playing SFX is stopped.
    @ObservationIgnored private var isSuspended: Bool = false

    enum SFX: String, CaseIterable {
        case navigate  = "sfx_navigate"
        case confirm   = "sfx_confirm"
        case back      = "sfx_back"
        case toggle    = "sfx_toggle"
        case error     = "sfx_error"
    }

    private var players: [SFX: AVAudioPlayer] = [:]

    // remote filenames on GitHub for each SFX.
    private static let remoteFiles: [SFX: String] = [
        .confirm:  "sfx_confirm.wav",
        .navigate: "sfx_navigate.wav",
        .back:     "sfx_back.wav",
        .toggle:   "sfx_toggle.wav",
        .error:    "sfx_error.wav",
    ]

    // local directory for cached SFX files.
    static var sfxRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("sfx", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private init() {
        let d = UserDefaults.standard
        self.enabled = d.object(forKey: "sakura.sfx.enabled") == nil
            ? true
            : d.bool(forKey: "sakura.sfx.enabled")
        self.volume = {
            let v = d.object(forKey: "sakura.sfx.volume") == nil
                ? Float(0.5)
                : d.float(forKey: "sakura.sfx.volume")
            return max(0, min(1, v))
        }()
        preload()
    }

    // MARK: - Bootstrap (auto-download on first boot)

    // call once at app launch. downloads any missing SFX files from GitHub
    // in the background, then reloads the player cache.
    func bootstrapIfNeeded() {
        // If all files exist locally, just mark ready.
        let allExist = SFX.allCases.allSatisfy { sfx in
            guard let file = Self.remoteFiles[sfx] else { return true }
            return FileManager.default.fileExists(atPath: Self.sfxRoot.appendingPathComponent(file).path)
        }
        if allExist {
            preload()
            isReady = true
            return
        }

        Task { [weak self] in
            await self?.downloadMissingSFX()
            self?.preload()
            self?.isReady = true
        }
    }

    private func downloadMissingSFX() async {
        let baseURL = MusicCatalog.assetsBaseURL
        let fm = FileManager.default

        await withTaskGroup(of: Void.self) { group in
            for sfx in SFX.allCases {
                guard let fileName = Self.remoteFiles[sfx] else { continue }
                let localPath = Self.sfxRoot.appendingPathComponent(fileName)
                guard !fm.fileExists(atPath: localPath.path) else { continue }
                guard let remote = URL(string: "\(baseURL)/sfx/\(fileName)") else { continue }

                group.addTask {
                    do {
                        let (tmp, response) = try await URLSession.shared.download(from: remote)
                        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                            try? FileManager.default.removeItem(at: localPath)
                            try FileManager.default.moveItem(at: tmp, to: localPath)
                        }
                    } catch {
                        // silent fail. SFX are non-critical.
                    }
                }
            }
        }
    }

    // MARK: - Playback

    func play(_ sfx: SFX) {
        guard enabled else { return }
        guard !isSuspended else { return }
        // Reduce Motion is a motion preference, not a mute switch.
        // SFX honour only enabled and volume.
        guard AudioSession.shared.ensureActiveForUIAudio() else { return }

        guard let player = players[sfx] else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    // MARK: - Game lifecycle

    // called when a game starts. stops any playing SFX and blocks further
    // playback until resumeAfterGame() is called.
    func suspendForGame() {
        isSuspended = true
        for player in players.values where player.isPlaying {
            player.stop()
        }
    }

    // called when the user returns to the Library. re-enables SFX playback.
    func resumeAfterGame() {
        isSuspended = false
    }

    // MARK: - Preload

    private func preload() {
        players.removeAll()
        for sfx in SFX.allCases {
            // Try local cached file first.
            if let fileName = Self.remoteFiles[sfx] {
                let localURL = Self.sfxRoot.appendingPathComponent(fileName)
                if let p = try? AVAudioPlayer(contentsOf: localURL) {
                    p.prepareToPlay()
                    players[sfx] = p
                    continue
                }
            }
            // Fallback: bundle (for dev/testing).
            if let url = Bundle.main.url(forResource: sfx.rawValue, withExtension: "wav")
                ?? Bundle.main.url(forResource: sfx.rawValue, withExtension: "mp3")
                ?? Bundle.main.url(forResource: sfx.rawValue, withExtension: "caf") {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.prepareToPlay()
                    players[sfx] = p
                }
            }
        }
    }

    // rebuild player cache, e.g. after the user swaps a sound pack.
    func reload() {
        players.removeAll()
        preload()
    }

    // MARK: - Attribution

    // SFX credits for the About section.
    // GitHub-hosted files:
    //   sfx_confirm.wav  from Christopherderp, Videogame Menu BUTTON CLICK
    //   sfx_navigate.wav from Foxfire-, Click / Tick / Menu Navigation
    //   sfx_back.wav     from sfx_navigate reversed (pre-processed)
    //   sfx_toggle.wav   from mellau, Button Click 1
    static let attributionLines: [(artist: String, description: String, license: String)] = [
        ("Christopherderp", "Freesound.org: Videogame Menu BUTTON CLICK (confirm)", "CC0 1.0"),
        ("Foxfire-", "Freesound.org: Click / Tick / Menu Navigation (navigate)", "CC0 1.0"),
        ("mellau", "Freesound.org: Button Click 1 (toggle)", "CC0 1.0"),
    ]
}
