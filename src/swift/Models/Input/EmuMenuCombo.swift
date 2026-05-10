// SPDX-License-Identifier: GPL-3.0+

import Foundation

enum EmuMenuComboPreset: String, CaseIterable, Identifiable {
    case l1r1
    case selectStart
    case l3r3
    case l3rx
    case custom

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .l1r1: return "controller.consmenu.l1r1"
        case .selectStart: return "controller.consmenu.selectStart"
        case .l3r3: return "controller.consmenu.l3r3"
        case .l3rx: return "controller.consmenu.l3rx"
        case .custom: return "controller.consmenu.custom"
        }
    }

    /// SDL-compatible indices (`SakuraGamepad` / `SakuraGamepadIOS`).
    /// For axes, we use a special offset: 100 + axisIndex.
    /// 102 = Right Stick X axis.
    var defaultPair: (Int, Int) {
        switch self {
        case .l1r1: return (9, 10)
        case .selectStart: return (4, 6)
        case .l3r3: return (7, 8)
        case .l3rx: return (7, 102)
        case .custom: return (-1, -1)
        }
    }
}

enum EmuMenuComboStorage {
    static let presetKey = "sakura.emuMenu.comboPreset"
    static let custom0Key = "sakura.emuMenu.comboCustom0"
    static let custom1Key = "sakura.emuMenu.comboCustom1"

    static var preset: EmuMenuComboPreset {
        get {
            let raw = UserDefaults.standard.string(forKey: presetKey) ?? EmuMenuComboPreset.l1r1.rawValue
            return EmuMenuComboPreset(rawValue: raw) ?? .l1r1
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: presetKey) }
    }

    static var custom0: Int {
        get {
            if UserDefaults.standard.object(forKey: custom0Key) == nil { return -1 }
            return UserDefaults.standard.integer(forKey: custom0Key)
        }
        set { UserDefaults.standard.set(newValue, forKey: custom0Key) }
    }

    static var custom1: Int {
        get {
            if UserDefaults.standard.object(forKey: custom1Key) == nil { return -1 }
            return UserDefaults.standard.integer(forKey: custom1Key)
        }
        set { UserDefaults.standard.set(newValue, forKey: custom1Key) }
    }

    static func resolvedPair() -> (Int, Int)? {
        let p = preset
        let a: Int
        let b: Int
        if p == .custom {
            a = custom0
            b = custom1
        } else {
            let pair = p.defaultPair
            a = pair.0
            b = pair.1
        }
        guard a >= 0, b >= 0, a != b else { return nil }
        let isValidA = (a < 26) || (a >= 100 && a < 106)
        let isValidB = (b < 26) || (b >= 100 && b < 106)
        guard isValidA, isValidB else { return nil }
        return (a, b)
    }

    private static func sdlCompositeKey(for code: Int) -> String {
        if code >= 100, code < 106 {
            switch code - 100 {
            case 0: return "controller.sdl.lStickX"
            case 1: return "controller.sdl.lStickY"
            case 2: return "controller.sdl.rStickX"
            case 3: return "controller.sdl.rStickY"
            case 4: return "controller.sdl.l2Axis"
            case 5: return "controller.sdl.r2Axis"
            default:
                return "controller.sdl.axisGeneric|\(code - 100)"
            }
        }
        switch code {
        case 0: return "controller.sdl.aCross"
        case 1: return "controller.sdl.bCircle"
        case 2: return "controller.sdl.xSquare"
        case 3: return "controller.sdl.yTriangle"
        case 4: return "controller.sdl.shareBack"
        case 5: return "controller.sdl.guidePs"
        case 6: return "controller.sdl.optionsStart"
        case 7: return "controller.sdl.lStickPress"
        case 8: return "controller.sdl.rStickPress"
        case 9: return "controller.sdl.lShoulder"
        case 10: return "controller.sdl.rShoulder"
        case 11: return "controller.sdl.dpadUp"
        case 12: return "controller.sdl.dpadDown"
        case 13: return "controller.sdl.dpadLeft"
        case 14: return "controller.sdl.dpadRight"
        case 15: return "controller.sdl.miscShare"
        case 20: return "controller.sdl.touchpad"
        default:
            return "controller.sdl.buttonGeneric|\(code)"
        }
    }

    private static func resolvedLabel(forKeyOrComposite raw: String) -> String {
        if let pipe = raw.firstIndex(of: "|") {
            let kind = String(raw[..<pipe])
            let arg = String(raw[raw.index(after: pipe)...])
            if kind == "controller.sdl.axisGeneric", let n = Int(arg) {
                return SakuraL10n.trf("controller.sdl.axisGeneric", n)
            }
            if kind == "controller.sdl.buttonGeneric", let n = Int(arg) {
                return SakuraL10n.trf("controller.sdl.buttonGeneric", n)
            }
        }
        return SakuraL10n.tr(raw)
    }

    static func displayLabel() -> String {
        let p = preset
        if p == .custom {
            let a = custom0
            let b = custom1
            guard a >= 0, b >= 0, a != b else { return SakuraL10n.tr("controller.consmenu.customUnset") }
            return "\(resolvedLabel(forKeyOrComposite: sdlCompositeKey(for: a))) + \(resolvedLabel(forKeyOrComposite: sdlCompositeKey(for: b)))"
        }
        return SakuraL10n.tr(p.labelKey)
    }
}
