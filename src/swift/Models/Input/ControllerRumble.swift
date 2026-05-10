// ControllerRumbleManager.swift: physical controller haptics from game rumble events
// SPDX-License-Identifier: GPL-3.0+

import Foundation
import GameController
import CoreHaptics
import UIKit

@MainActor
final class ControllerRumbleManager {
    static let shared = ControllerRumbleManager()

    private var observer: NSObjectProtocol?
    // Two engines: large (low-frequency motor) + small (high-frequency motor).
    // DualSense / Xbox Series controllers expose locality .leftHandle and
    // .rightHandle separately, so we drive the two motors independently when
    // possible. Falls back to .default if the locality isn't supported.
    private var largeEngine: CHHapticEngine?
    private var smallEngine: CHHapticEngine?
    private var engineController: GCController?
    private var lastLarge: Float = 0
    private var lastSmall: Float = 0
    private var lastPhoneFire: TimeInterval = 0
    private var started = false

    // phone fallback impact generators (prepare once so the first use isn't laggy)
    private let phoneSoftImpact = UIImpactFeedbackGenerator(style: .soft)
    private let phoneMediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let phoneHeavyImpact = UIImpactFeedbackGenerator(style: .heavy)

    private init() {
        phoneSoftImpact.prepare()
        phoneMediumImpact.prepare()
        phoneHeavyImpact.prepare()
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true

        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SakuraVibrationUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let large = (info["large"] as? NSNumber)?.floatValue,
                  let small = (info["small"] as? NSNumber)?.floatValue else { return }
            Task { @MainActor in
                self.handleVibration(large: large, small: small)
            }
        }
    }

    private func handleVibration(large: Float, small: Float) {
        guard SettingsStore.shared.controllerRumbleEnabled else {
            stopHaptics()
            return
        }

        let intensity = SettingsStore.shared.controllerRumbleIntensity
        let scaledLarge = min(large * intensity, 1.0)
        let scaledSmall = min(small * intensity, 1.0)

        // Coalesce duplicate updates so games that re-issue identical rumble
        // commands every frame don't spam the haptic engine.
        if scaledLarge == lastLarge && scaledSmall == lastSmall { return }
        lastLarge = scaledLarge
        lastSmall = scaledSmall

        if scaledLarge <= 0.001 && scaledSmall <= 0.001 {
            stopHaptics()
            return
        }

        // Prefer a real controller with native haptics. If none, fall back to
        // the phone's haptic engine when the user opted in.
        if let (controller, haptics) = firstControllerWithHaptics() {
            playControllerHaptic(controller: controller, haptics: haptics, large: scaledLarge, small: scaledSmall)
        } else if SettingsStore.shared.phoneVibrationFallback {
            playPhoneFallback(large: scaledLarge, small: scaledSmall)
        }
    }

    private func firstControllerWithHaptics() -> (GCController, GCDeviceHaptics)? {
        // GCController.current is only set after the user has interacted with a
        // specific controller, so iterate the full list. Skip GCVirtualController
        // (the on-screen pad) which has no real motors anyway.
        for c in GCController.controllers() {
            if NSStringFromClass(type(of: c) as AnyClass).contains("GCVirtualController") { continue }
            if let h = c.haptics { return (c, h) }
        }
        if let cur = GCController.current, let h = cur.haptics { return (cur, h) }
        return nil
    }

    private func playControllerHaptic(controller: GCController, haptics: GCDeviceHaptics, large: Float, small: Float) {
        // Recreate engines if the active controller changed or if a previous
        // engine creation/start failed and left us with nothing to play on.
        if engineController !== controller || largeEngine == nil {
            stopHaptics()
            engineController = controller
            largeEngine = makeEngine(haptics: haptics, locality: .leftHandle) ?? makeEngine(haptics: haptics, locality: .default)
            smallEngine = makeEngine(haptics: haptics, locality: .rightHandle)
            // if the controller has only one locality (.default), reuse the
            // large engine for the small motor. the device will mix them.
            if smallEngine == nil { smallEngine = largeEngine }
        }

        // Fall back to phone vibration if every engine attempt failed and the
        // user has the fallback enabled, so they still get tactile feedback.
        if largeEngine == nil && smallEngine == nil {
            if SettingsStore.shared.phoneVibrationFallback {
                playPhoneFallback(large: large, small: small)
            }
            return
        }

        playMotor(engine: largeEngine, intensity: large, sharpness: 0.2)   // large = dull / low-frequency
        playMotor(engine: smallEngine, intensity: small, sharpness: 0.95)  // small = sharp / high-frequency
    }

    private func makeEngine(haptics: GCDeviceHaptics, locality: GCHapticsLocality) -> CHHapticEngine? {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        engine.isAutoShutdownEnabled = true
        engine.playsHapticsOnly = true
        engine.resetHandler = { [weak engine] in
            Task { @MainActor in
                try? engine?.start()
            }
        }
        do {
            try engine.start()
            return engine
        } catch {
            return nil
        }
    }

    private func playMotor(engine: CHHapticEngine?, intensity: Float, sharpness: Float) {
        guard let engine, intensity > 0.001 else { return }
        do {
            let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: 0,
                duration: 0.25
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // ignore. next pump will retry.
        }
    }

    // Phone fallback: UIImpactFeedbackGenerator only fires discrete pulses, so we
    // throttle it to ~12 Hz. Picks a style based on how strong the rumble is.
    private func playPhoneFallback(large: Float, small: Float) {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastPhoneFire < 0.08 { return }
        lastPhoneFire = now
        let combined = max(large, small)
        if combined < 0.15 { return }
        if combined > 0.66 {
            phoneHeavyImpact.impactOccurred(intensity: CGFloat(combined))
            phoneHeavyImpact.prepare()
        } else if combined > 0.33 {
            phoneMediumImpact.impactOccurred(intensity: CGFloat(combined))
            phoneMediumImpact.prepare()
        } else {
            phoneSoftImpact.impactOccurred(intensity: CGFloat(combined))
            phoneSoftImpact.prepare()
        }
    }

    private func stopHaptics() {
        largeEngine?.stop(completionHandler: nil)
        smallEngine?.stop(completionHandler: nil)
        largeEngine = nil
        smallEngine = nil
        engineController = nil
        lastLarge = 0
        lastSmall = 0
    }
}
