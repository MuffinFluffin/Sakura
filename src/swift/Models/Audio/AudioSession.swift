// AudioSession.swift: shared AVAudioSession owner.
//
// MusicPlayer and SFXManager both route through this singleton so the
// session category/activation state has one source of truth. .playback +
// .mixWithOthers lets UI sounds and menu music layer over Spotify, Apple
// Music, podcasts without interrupting them. SFX keep playing even when
// the user never started menu music.
//
// SPDX-License-Identifier: GPL-3.0+

import AVFoundation
import Foundation

@MainActor
final class AudioSession {
    static let shared = AudioSession()

    // true while a game is running and we've stepped aside so the emulator
    // has full audio priority. while suspended, ensureActiveForUIAudio()
    // becomes a no-op so SFX cannot yank the session back in-game.
    private(set) var isSuspendedForGame: Bool = false

    // tracks whether the session is active with the UI-audio category.
    // cheap guard so repeated ensureActiveForUIAudio() calls do not hammer the API.
    private var isActive: Bool = false

    private init() {}

    // idempotently sets the UI-audio category (.playback + .mixWithOthers)
    // and activates the session. safe to call from any UI audio path.
    // returns true if the session is ready for playback, false when suspended for a running game.
    @discardableResult
    func ensureActiveForUIAudio() -> Bool {
        guard !isSuspendedForGame else { return false }
        guard !isActive else { return true }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            isActive = true
            return true
        } catch {
            SakuraLogUnified("Audio", "Warning", "ensureActiveForUIAudio failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Hand the audio session back to other apps while a game is running.
    /// Callers should pair this with `resumeForUIAudio()` on game exit.
    func suspendForGame() {
        isSuspendedForGame = true
        // We no longer deactivate the session here because the emulator's CoreAudio
        // backend relies on the session being active to output game audio.
    }

    /// Re-take the session after a game ends and the user is back in menus.
    /// Kept separate from `ensureActiveForUIAudio()` so the game-end path is
    /// explicit in reads.
    func resumeForUIAudio() {
        isSuspendedForGame = false
        _ = ensureActiveForUIAudio()
    }
}
