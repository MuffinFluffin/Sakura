// ControllerEvents.swift: observes GCController connect/disconnect
// and posts notification cards. Runs alongside GamepadNavigation so
// the latter can focus on input routing without owning toast UI.
// SPDX-License-Identifier: GPL-3.0+

import Foundation
import GameController

@MainActor
final class ControllerEvents {
    static let shared = ControllerEvents()

    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func startIfNeeded() {
        guard !started else { return }
        started = true

        let c = NotificationCenter.default

        // GCController isn't Sendable, so we extract the display name and
        // the "is virtual pad" flag inside the observer callback (which
        // runs on main because we pass `queue: .main`), then pass only
        // Sendable primitives into the @MainActor Task.
        observers.append(c.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { note in
            guard let controller = note.object as? GCController else { return }
            if NSStringFromClass(type(of: controller) as AnyClass).contains("GCVirtualController") {
                return
            }
            let name = controller.vendorName ?? "Controller"
            Task { @MainActor in
                SakuraNotificationCenter.shared.post(.controller(connected: true, name: name))
            }
        })

        observers.append(c.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { note in
            guard let controller = note.object as? GCController else { return }
            if NSStringFromClass(type(of: controller) as AnyClass).contains("GCVirtualController") {
                return
            }
            let name = controller.vendorName ?? "Controller"
            Task { @MainActor in
                SakuraNotificationCenter.shared.post(.controller(connected: false, name: name))
            }
        })
    }
}
