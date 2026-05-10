// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import Combine

enum EmulatorState: String {
    case stopped = "Stopped"
    case running = "Running"
    case paused = "Paused"
    case saving = "Saving"
    case suspended = "Suspended"
}

@Observable
final class EmulatorBridge: @unchecked Sendable {
    static let shared = EmulatorBridge()

    var state: EmulatorState = .stopped
    var lastSaveDate: Date? = nil
    var lastSaveSuccess: Bool = true
    var biosName: String = "Unknown"
    var buildVersion: String = ""

    private init() {
        biosName = SakuraBridge.biosName()
        buildVersion = SakuraBridge.buildVersion()
    }

    func saveAll() {
        state = .saving
        SakuraBridge.saveAllState()
        lastSaveDate = Date()
        lastSaveSuccess = true
        state = .running
    }

    func setPadButton(_ button: PadButton, pressed: Bool) {
        PadInputRouter.dispatch(button, pressed: pressed)
    }

    func setLeftStick(x: Float, y: Float) {
        PadInputRouter.dispatchLeftStick(x: x, y: y)
    }

    func setRightStick(x: Float, y: Float) {
        PadInputRouter.dispatchRightStick(x: x, y: y)
    }

    var isOsdVisible: Bool {
        get { SakuraBridge.isPerformanceOverlayVisible() }
        set { SakuraBridge.setPerformanceOverlayVisible(newValue) }
    }
}
