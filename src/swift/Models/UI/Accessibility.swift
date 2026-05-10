// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

// MARK: - View helpers (VoiceOver + accessibility settings)

extension View {
    @ViewBuilder
    func sakuraA11y(_ label: String, hint: String? = nil, value: String? = nil) -> some View {
        if let hint, let value {
            self
                .accessibilityLabel(label)
                .accessibilityHint(hint)
                .accessibilityValue(value)
        } else if let hint {
            self
                .accessibilityLabel(label)
                .accessibilityHint(hint)
        } else if let value {
            self
                .accessibilityLabel(label)
                .accessibilityValue(value)
        } else {
            self.accessibilityLabel(label)
        }
    }
}

// MARK: - virtual pad (PadButton is bridged from Obj-C)

func sakuraA11yPadName(_ b: PadButton) -> String {
    switch b {
    case .up: return SakuraL10n.tr("controller.map.dpad.up")
    case .down: return SakuraL10n.tr("controller.map.dpad.down")
    case .left: return SakuraL10n.tr("controller.map.dpad.left")
    case .right: return SakuraL10n.tr("controller.map.dpad.right")
    case .cross: return SakuraL10n.tr("controller.map.face.crossSymbol")
    case .circle: return SakuraL10n.tr("controller.map.face.circle")
    case .square: return SakuraL10n.tr("controller.map.face.square")
    case .triangle: return SakuraL10n.tr("controller.map.face.triangleSymbol")
    case .L1: return SakuraL10n.tr("controller.map.face.l1")
    case .R1: return SakuraL10n.tr("controller.map.face.r1")
    case .L2: return SakuraL10n.tr("pad.group.l2")
    case .R2: return SakuraL10n.tr("pad.group.r2")
    case .start: return SakuraL10n.tr("controller.map.face.startBtn")
    case .select: return SakuraL10n.tr("controller.map.face.selectBtn")
    case .L3: return SakuraL10n.tr("controller.map.face.l3")
    case .R3: return SakuraL10n.tr("controller.map.face.r3")
    @unknown default: return SakuraL10n.tr("accessibility.vpad.unknownControl")
    }
}
