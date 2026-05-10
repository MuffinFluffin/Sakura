// SPDX-License-Identifier: GPL-3.0+

import Foundation
import SwiftUI

enum PadInputRouter {
    static func dispatch(_ button: PadButton, pressed: Bool) {
        let run = { @MainActor in dispatchOnMain(button, pressed: pressed) }
        if Thread.isMainThread {
            MainActor.assumeIsolated { run() }
        } else {
            DispatchQueue.main.async { run() }
        }
    }

    static func dispatchLeftStick(x: Float, y: Float) {
        let run = { @MainActor in dispatchStickOnMain(left: true, x: x, y: y) }
        if Thread.isMainThread {
            MainActor.assumeIsolated { run() }
        } else {
            DispatchQueue.main.async { run() }
        }
    }

    static func dispatchRightStick(x: Float, y: Float) {
        let run = { @MainActor in dispatchStickOnMain(left: false, x: x, y: y) }
        if Thread.isMainThread {
            MainActor.assumeIsolated { run() }
        } else {
            DispatchQueue.main.async { run() }
        }
    }

    @MainActor
    private static func dispatchStickOnMain(left: Bool, x: Float, y: Float) {
        guard !isRemote(SecondaryDisplayCoordinator.shared) else { return }
        if left {
            SakuraBridge.setLeftStickX(x, y: y, port: 0)
        } else {
            SakuraBridge.setRightStickX(x, y: y, port: 0)
        }
    }

    @MainActor
    private static func dispatchOnMain(_ button: PadButton, pressed: Bool) {
        let c = SecondaryDisplayCoordinator.shared
        if isRemote(c), pressed {
            handleRemotePress(button)
            return
        }
        if isRemote(c), !pressed {
            SakuraBridge.setPadButton(button, pressed: false, port: 0)
            return
        }
        SakuraBridge.setPadButton(button, pressed: pressed, port: 0)
    }

    @MainActor
    private static func isRemote(_ c: SecondaryDisplayCoordinator) -> Bool {
        // the phone is acting as a remote whenever it's hosting PhoneRemoteView,
        // i.e. TV mode with an external display attached and no Stop-TV
        // suspension. in Handheld mode the phone keeps its normal chrome and
        // touches always route to gameplay/UI directly.
        guard c.mode == .tv,
              c.externalRasterSurfaceAvailable,
              !c.externalBrowsingSuspended
        else { return false }
        return AppState.shared.currentScreen != .playing
    }

    @MainActor
    private static func handleRemotePress(_ button: PadButton) {
        let scr = AppState.shared.currentScreen
        if button == .start {
            if scr == .settings {
                AppState.shared.returnToMenu()
            } else {
                AppState.shared.openSettings()
            }
            return
        }

        guard let action = navAction(for: button) else { return }
        let nav = GamepadNavigation.shared
        nav.lastAction = action
        nav.actionID &+= 1
    }

    @MainActor
    private static func navAction(for button: PadButton) -> GamepadAction? {
        switch button {
        case .up: return .moveUp
        case .down: return .moveDown
        case .left: return .moveLeft
        case .right: return .moveRight
        case .cross: return .confirm
        case .circle: return .back
        case .square: return .secondary
        case .triangle: return .tertiary
        case .L1: return .shoulderLeft
        case .R1: return .shoulderRight
        case .select: return .menu
        default: return nil
        }
    }
}
