// SPDX-License-Identifier: GPL-3.0+

import UIKit

@MainActor
enum HapticManager {
    private static func impactOccurred(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }

    static func firePrimary() {
        guard SettingsStore.shared.hapticFeedback else { return }
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        switch ThemeManager.shared.hapticIntensityKey {
        case "off": return
        case "light": impactOccurred(style: .light)
        case "strong": impactOccurred(style: .heavy)
        default: impactOccurred(style: .medium)
        }
    }

    static func fireSecondary() {
        guard SettingsStore.shared.hapticFeedback else { return }
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        switch ThemeManager.shared.hapticIntensityKey {
        case "off": return
        case "strong": impactOccurred(style: .medium)
        default: impactOccurred(style: .light)
        }
    }
}
