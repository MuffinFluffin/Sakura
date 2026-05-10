// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

struct PadGroupPosition {
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat
}

@Observable
final class PadLayoutStore: @unchecked Sendable {
    static let shared = PadLayoutStore()

    static let groupIDs = [
        "dpad",
        "btn_triangle", "btn_circle", "btn_cross", "btn_square",
        "l1", "l2", "r1", "r2",
        "lstick", "rstick",
        "select", "start",
    ]

    static func localizedGroupLabel(for id: String) -> String {
        let key: String
        switch id {
        case "dpad": key = "pad.group.dpad"
        case "btn_triangle": key = "pad.group.triangle"
        case "btn_circle": key = "pad.group.circle"
        case "btn_cross": key = "pad.group.cross"
        case "btn_square": key = "pad.group.square"
        case "l1": key = "pad.group.l1"
        case "l2": key = "pad.group.l2"
        case "r1": key = "pad.group.r1"
        case "r2": key = "pad.group.r2"
        case "lstick": key = "pad.group.leftStick"
        case "rstick": key = "pad.group.rightStick"
        case "select": key = "pad.group.select"
        case "start": key = "pad.group.start"
        default:
            return id.capitalized
        }
        let s = SakuraL10n.tr(key)
        if s == key { return id.capitalized }
        return s
    }

    static let groupIcons: [String: String] = [
        "dpad":         "dpad.fill",
        "btn_triangle": "triangle.fill",
        "btn_circle":   "circle",
        "btn_cross":    "xmark",
        "btn_square":   "square",
        "l1":           "l1.button.roundedbottom.horizontal",
        "l2":           "l2.button.roundedbottom.horizontal",
        "r1":           "r1.button.roundedbottom.horizontal",
        "r2":           "r2.button.roundedbottom.horizontal",
        "lstick":       "l.joystick",
        "rstick":       "r.joystick",
        "select":       "rectangle.on.rectangle",
        "start":        "line.3.horizontal",
    ]

    static func layoutGroupIDs(forPS1Mode mode: Int) -> [String] {
        guard mode == 0 else { return groupIDs }
        return groupIDs.filter { id in
            id != "lstick" && id != "rstick" && id != "l3" && id != "r3"
        }
    }

    var positions: [String: PadGroupPosition] = [:]
    var globalScale: CGFloat = 1.14

    var colors: [String: String] = [:]
    var strokeColors: [String: String] = [:]

    private(set) var activeMode: Int = 1
    private var activeModeName: String { activeMode == 0 ? "Digital" : "DualShock" }
    private func positionsSection() -> String { "Sakura/PadLayout/Positions/\(activeModeName)" }
    private func colorsSection() -> String { "Sakura/PadLayout/Colors/\(activeModeName)" }
    private func strokeColorsSection() -> String { "Sakura/PadLayout/StrokeColors/\(activeModeName)" }

    private static let defaultPositionsDualShock: [String: PadGroupPosition] = [
        "dpad":         PadGroupPosition(x: 0.258452, y: 0.571061, scale: 0.8),
        "btn_triangle": PadGroupPosition(x: 0.887657, y: 0.649242, scale: 1.0),
        "btn_circle":   PadGroupPosition(x: 0.741715, y: 0.717727, scale: 1.0),
        "btn_cross":    PadGroupPosition(x: 0.733891, y: 0.911212, scale: 1.0),
        "btn_square":   PadGroupPosition(x: 0.809749, y: 0.632121, scale: 1.0),
        "l2":           PadGroupPosition(x: 0.340000, y: 0.740000, scale: 1.0),
        "l1":           PadGroupPosition(x: 0.340000, y: 0.880000, scale: 1.0),
        "r2":           PadGroupPosition(x: 0.600000, y: 0.740000, scale: 1.0),
        "r1":           PadGroupPosition(x: 0.600000, y: 0.880000, scale: 1.0),
        "select":       PadGroupPosition(x: 0.470000, y: 0.880000, scale: 1.0),
        "start":        PadGroupPosition(x: 0.470000, y: 0.780000, scale: 1.0),
        "lstick":       PadGroupPosition(x: 0.172037, y: 0.748485, scale: 1.2),
        "rstick":       PadGroupPosition(x: 0.832845, y: 0.839394, scale: 1.0),
    ]

    private static let defaultPositionsDigital: [String: PadGroupPosition] = [
        "dpad":         PadGroupPosition(x: 0.177559, y: 0.688485, scale: 1.2),
        "btn_triangle": PadGroupPosition(x: 0.854184, y: 0.715909, scale: 1.0),
        "btn_circle":   PadGroupPosition(x: 0.834114, y: 0.882121, scale: 1.0),
        "btn_cross":    PadGroupPosition(x: 0.748187, y: 0.884697, scale: 1.0),
        "btn_square":   PadGroupPosition(x: 0.782204, y: 0.730606, scale: 1.0),
        "l2":           PadGroupPosition(x: 0.340000, y: 0.740000, scale: 1.0),
        "l1":           PadGroupPosition(x: 0.340000, y: 0.880000, scale: 1.0),
        "r2":           PadGroupPosition(x: 0.600000, y: 0.740000, scale: 1.0),
        "r1":           PadGroupPosition(x: 0.600000, y: 0.880000, scale: 1.0),
        "select":       PadGroupPosition(x: 0.470000, y: 0.880000, scale: 1.0),
        "start":        PadGroupPosition(x: 0.470000, y: 0.780000, scale: 1.0),
        "lstick":       PadGroupPosition(x: 0.300000, y: 0.550000, scale: 1.0),
        "rstick":       PadGroupPosition(x: 0.700000, y: 0.550000, scale: 1.0),
    ]

    static func defaultPositions(forPS1Mode mode: Int) -> [String: PadGroupPosition] {
        mode == 0 ? defaultPositionsDigital : defaultPositionsDualShock
    }

    private init() {
        let modeFromBridge = Int(SakuraBridge.ps1ControllerMode(forGame: SakuraBridge.currentISOPath() ?? ""))
        activeMode = (modeFromBridge == 0 || modeFromBridge == 1) ? modeFromBridge : 1
        positions = Self.defaultPositions(forPS1Mode: activeMode)
        load()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SakuraPS1ControllerModeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let next = Int(SakuraBridge.ps1ControllerMode(forGame: SakuraBridge.currentISOPath() ?? ""))
            self.switchActiveMode(to: next)
        }
    }

    private func switchActiveMode(to mode: Int) {
        guard (mode == 0 || mode == 1), mode != activeMode else { return }
        save()
        activeMode = mode
        positions = Self.defaultPositions(forPS1Mode: mode)
        colors = [:]
        strokeColors = [:]
        load()
    }

    // swap which saved layout preset we're editing during Edit Layout. does not change the game's controller mode bridge.
    func switchEditingPreset(_ mode: Int) {
        switchActiveMode(to: mode)
    }

    // reload to match the game's controller mode preset when leaving the overlay editor.
    func syncLayoutPresetFromBridge() {
        let next = Int(SakuraBridge.ps1ControllerMode(forGame: SakuraBridge.currentISOPath() ?? ""))
        guard next == 0 || next == 1 else { return }
        switchActiveMode(to: next)
    }

    func position(for id: String) -> PadGroupPosition {
        let defaults = Self.defaultPositions(forPS1Mode: activeMode)
        return positions[id] ?? defaults[id] ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
    }

    func setScale(_ scale: CGFloat, for id: String) {
        let clamped = max(0.5, min(1.8, scale))
        var p = positions[id] ?? Self.defaultPositions(forPS1Mode: activeMode)[id] ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
        p.scale = clamped
        positions[id] = p
        save()
    }

    func setGlobalScale(_ scale: CGFloat) {
        let clamped = max(0.5, min(2.0, scale))
        globalScale = clamped
        SakuraBridge.setINIFloat("Sakura/PadLayout", key: "global_scale", value: Float(clamped))
    }

    func colorKey(for id: String) -> String {
        colors[id] ?? ""
    }

    func setColorKey(_ key: String, for id: String) {
        colors[id] = key
        SakuraBridge.setINIString(colorsSection(), key: id, value: key)
    }

    func strokeColorKey(for id: String) -> String {
        strokeColors[id] ?? ""
    }

    func setStrokeColorKey(_ key: String, for id: String) {
        strokeColors[id] = key
        SakuraBridge.setINIString(strokeColorsSection(), key: id, value: key)
    }

    func save() {
        SakuraBridge.setINIFloat("Sakura/PadLayout", key: "global_scale", value: Float(globalScale))
        let posSec = positionsSection()
        let colorsSec = colorsSection()
        let strokeColorsSec = strokeColorsSection()
        for id in Self.groupIDs {
            if let pos = positions[id] {
                SakuraBridge.setINIFloat(posSec, key: "\(id)_x", value: Float(pos.x))
                SakuraBridge.setINIFloat(posSec, key: "\(id)_y", value: Float(pos.y))
                SakuraBridge.setINIFloat(posSec, key: "\(id)_scale", value: Float(pos.scale))
            }
            SakuraBridge.setINIString(colorsSec, key: id, value: colors[id] ?? "")
            SakuraBridge.setINIString(strokeColorsSec, key: id, value: strokeColors[id] ?? "")
        }
    }

    func load() {
        globalScale = CGFloat(SakuraBridge.getINIFloat("Sakura/PadLayout", key: "global_scale", defaultValue: 1.14))
        globalScale = max(0.5, min(2.0, globalScale))
        migratePerModeLandscapeFromSharedIfNeeded()
        migrateLandscapePerModeIntoPositionsIfNeeded()
        let posSec = positionsSection()
        let colorsSec = colorsSection()
        let strokeColorsSec = strokeColorsSection()
        for id in Self.groupIDs {
            let px = SakuraBridge.getINIFloat(posSec, key: "\(id)_x", defaultValue: -1)
            if px >= 0 {
                let py = SakuraBridge.getINIFloat(posSec, key: "\(id)_y", defaultValue: 0.5)
                let ps = SakuraBridge.getINIFloat(posSec, key: "\(id)_scale", defaultValue: 1.0)
                positions[id] = PadGroupPosition(x: CGFloat(px), y: CGFloat(py), scale: CGFloat(ps))
            }
            colors[id] = SakuraBridge.getINIString(colorsSec, key: id, defaultValue: "")
            strokeColors[id] = SakuraBridge.getINIString(strokeColorsSec, key: id, defaultValue: "")
        }
        migrateLegacyActionIfNeeded()
    }

    /// shared `Sakura/PadLayout/Landscape` + shared colours → per-controller-mode sections (no portrait).
    private func migratePerModeLandscapeFromSharedIfNeeded() {
        let migrationKey = "per_mode_v1"
        if SakuraBridge.getINIString("Sakura/PadLayout", key: migrationKey, defaultValue: "") == "1" { return }
        let modes = ["Digital", "DualShock"]
        for id in Self.groupIDs {
            let lx = SakuraBridge.getINIFloat("Sakura/PadLayout/Landscape", key: "\(id)_x", defaultValue: -1)
            if lx >= 0 {
                let ly = SakuraBridge.getINIFloat("Sakura/PadLayout/Landscape", key: "\(id)_y", defaultValue: 0.5)
                let ls = SakuraBridge.getINIFloat("Sakura/PadLayout/Landscape", key: "\(id)_scale", defaultValue: 1.0)
                for m in modes {
                    SakuraBridge.setINIFloat("Sakura/PadLayout/Landscape/\(m)", key: "\(id)_x", value: lx)
                    SakuraBridge.setINIFloat("Sakura/PadLayout/Landscape/\(m)", key: "\(id)_y", value: ly)
                    SakuraBridge.setINIFloat("Sakura/PadLayout/Landscape/\(m)", key: "\(id)_scale", value: ls)
                }
            }
            let storedColor = SakuraBridge.getINIString("Sakura/PadLayout/Colors", key: id, defaultValue: "")
            if !storedColor.isEmpty {
                for m in modes {
                    SakuraBridge.setINIString("Sakura/PadLayout/Colors/\(m)", key: id, value: storedColor)
                }
            }
            let storedStroke = SakuraBridge.getINIString("Sakura/PadLayout/StrokeColors", key: id, defaultValue: "")
            if !storedStroke.isEmpty {
                for m in modes {
                    SakuraBridge.setINIString("Sakura/PadLayout/StrokeColors/\(m)", key: id, value: storedStroke)
                }
            }
        }
        SakuraBridge.setINIString("Sakura/PadLayout", key: migrationKey, value: "1")
    }

    /// legacy `Landscape/<Mode>` rows → `Positions/<Mode>`
    private func migrateLandscapePerModeIntoPositionsIfNeeded() {
        let migrationKey = "positions_ini_v1"
        if SakuraBridge.getINIString("Sakura/PadLayout", key: migrationKey, defaultValue: "") == "1" { return }
        let modes = ["Digital", "DualShock"]
        for mode in modes {
            let fromPrefix = "Sakura/PadLayout/Landscape/\(mode)"
            let toPrefix = "Sakura/PadLayout/Positions/\(mode)"
            for id in Self.groupIDs {
                let lx = SakuraBridge.getINIFloat(fromPrefix, key: "\(id)_x", defaultValue: -1)
                guard lx >= 0 else { continue }
                let ly = SakuraBridge.getINIFloat(fromPrefix, key: "\(id)_y", defaultValue: 0.5)
                let ls = SakuraBridge.getINIFloat(fromPrefix, key: "\(id)_scale", defaultValue: 1.0)
                SakuraBridge.setINIFloat(toPrefix, key: "\(id)_x", value: lx)
                SakuraBridge.setINIFloat(toPrefix, key: "\(id)_y", value: ly)
                SakuraBridge.setINIFloat(toPrefix, key: "\(id)_scale", value: ls)
            }
        }
        SakuraBridge.setINIString("Sakura/PadLayout", key: migrationKey, value: "1")
    }

    private func migrateLegacyActionIfNeeded() {
        let legacyLandscapeX = SakuraBridge.getINIFloat("Sakura/PadLayout/Landscape", key: "action_x", defaultValue: -1)
        if legacyLandscapeX >= 0 {
            let y = SakuraBridge.getINIFloat("Sakura/PadLayout/Landscape", key: "action_y", defaultValue: 0.72)
            let s = SakuraBridge.getINIFloat("Sakura/PadLayout/Landscape", key: "action_scale", defaultValue: 1.0)
            explodeActionInto(&positions, centerX: CGFloat(legacyLandscapeX), centerY: CGFloat(y), scale: CGFloat(s), offset: 0.06)
        }
        let legacyTint = SakuraBridge.getINIString("Sakura/PadLayout/Colors", key: "action", defaultValue: "")
        if !legacyTint.isEmpty {
            for id in ["btn_triangle", "btn_circle", "btn_cross", "btn_square"] where (colors[id] ?? "").isEmpty {
                colors[id] = legacyTint
            }
        }
    }

    private func explodeActionInto(_ dict: inout [String: PadGroupPosition], centerX: CGFloat, centerY: CGFloat, scale: CGFloat, offset: CGFloat) {
        if dict["btn_triangle"] == nil { dict["btn_triangle"] = PadGroupPosition(x: centerX,          y: centerY - offset, scale: scale) }
        if dict["btn_circle"]   == nil { dict["btn_circle"]   = PadGroupPosition(x: centerX + offset, y: centerY,          scale: scale) }
        if dict["btn_cross"]    == nil { dict["btn_cross"]    = PadGroupPosition(x: centerX,          y: centerY + offset, scale: scale) }
        if dict["btn_square"]   == nil { dict["btn_square"]   = PadGroupPosition(x: centerX - offset, y: centerY,          scale: scale) }
    }

    func reset() {
        positions = Self.defaultPositions(forPS1Mode: activeMode)
        save()
    }

    func resetColors() {
        let colorsSec = colorsSection()
        let strokeColorsSec = strokeColorsSection()
        for id in Self.groupIDs {
            colors[id] = ""
            SakuraBridge.setINIString(colorsSec, key: id, value: "")
            strokeColors[id] = ""
            SakuraBridge.setINIString(strokeColorsSec, key: id, value: "")
        }
    }

    @MainActor
    private func makeExportedLayoutJSONData() throws -> Data {
        save()
        let digital = PadLayoutStore.readExportPreset(forModeIndex: 0)
        let dualShock = PadLayoutStore.readExportPreset(forModeIndex: 1)
        var gs = CGFloat(SakuraBridge.getINIFloat(
            "Sakura/PadLayout",
            key: "global_scale",
            defaultValue: Float(globalScale)
        ))
        gs = max(0.5, min(2.0, gs))
        let envelope = PadLayoutExportEnvelope(
            globalScale: Double(gs),
            digital: digital,
            dualShock: dualShock
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(envelope)
    }

    @MainActor
    func exportLayoutsToTemporaryJSONURL() throws -> URL {
        let data = try makeExportedLayoutJSONData()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let name = "PadLayout-\(fmt.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    func copyExportedLayoutJSONToPasteboard() throws {
        let data = try makeExportedLayoutJSONData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "PadLayout",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Exported layout was not valid UTF-8 text."]
            )
        }
        UIPasteboard.general.string = text
    }

    private static func readExportPreset(forModeIndex modeIndex: Int) -> PadLayoutExportPreset {
        let modeName = modeIndex == 0 ? "Digital" : "DualShock"
        let posSection = "Sakura/PadLayout/Positions/\(modeName)"
        let colorsExpSection = "Sakura/PadLayout/Colors/\(modeName)"
        let strokesExpSection = "Sakura/PadLayout/StrokeColors/\(modeName)"
        let defs = PadLayoutStore.defaultPositions(forPS1Mode: modeIndex)
        var positions: [String: PadLayoutExportCoords] = [:]
        for id in PadLayoutStore.groupIDs {
            let fallback = defs[id] ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
            let px = SakuraBridge.getINIFloat(posSection, key: "\(id)_x", defaultValue: -1)
            let xr: CGFloat
            let yr: CGFloat
            let sr: CGFloat
            if px >= 0 {
                xr = CGFloat(px)
                yr = CGFloat(SakuraBridge.getINIFloat(posSection, key: "\(id)_y", defaultValue: Float(fallback.y)))
                sr = CGFloat(SakuraBridge.getINIFloat(posSection, key: "\(id)_scale", defaultValue: Float(fallback.scale)))
            } else {
                xr = fallback.x
                yr = fallback.y
                sr = fallback.scale
            }
            positions[id] = PadLayoutExportCoords(x: Double(xr), y: Double(yr), scale: Double(sr))
        }
        var cols: [String: String] = [:]
        var strokes: [String: String] = [:]
        for id in PadLayoutStore.groupIDs {
            cols[id] = SakuraBridge.getINIString(colorsExpSection, key: id, defaultValue: "")
            strokes[id] = SakuraBridge.getINIString(strokesExpSection, key: id, defaultValue: "")
        }
        return PadLayoutExportPreset(positions: positions, colors: cols, strokeColors: strokes)
    }
}

private struct PadLayoutExportEnvelope: Codable {
    let formatVersion: Int
    let host: PadLayoutExportHost
    let globalScale: Double
    let digital: PadLayoutExportPreset
    let dualShock: PadLayoutExportPreset

    @MainActor
    init(globalScale: Double, digital: PadLayoutExportPreset, dualShock: PadLayoutExportPreset) {
        let scr = UIScreen.main
        let pts = scr.bounds.size
        let px = scr.nativeBounds.size
        self.formatVersion = 2
        self.host = PadLayoutExportHost(
            hwMachineIdentifier: DeviceInfo.machineID,
            deviceMarketingModelName: DeviceInfo.modelName,
            iosSystemVersion: DeviceInfo.iosVersion,
            screenBoundsWidthPoints: Double(pts.width),
            screenBoundsHeightPoints: Double(pts.height),
            screenNativeBoundsWidthPx: Double(px.width),
            screenNativeBoundsHeightPx: Double(px.height),
            screenScaleBoundsToPoints: Double(scr.scale),
            screenNativeScale: Double(scr.nativeScale)
        )
        self.globalScale = globalScale
        self.digital = digital
        self.dualShock = dualShock
    }
}

private struct PadLayoutExportHost: Codable {
    let hwMachineIdentifier: String
    let deviceMarketingModelName: String
    let iosSystemVersion: String
    let screenBoundsWidthPoints: Double
    let screenBoundsHeightPoints: Double
    let screenNativeBoundsWidthPx: Double
    let screenNativeBoundsHeightPx: Double
    let screenScaleBoundsToPoints: Double
    let screenNativeScale: Double
}

private struct PadLayoutExportPreset: Codable {
    let positions: [String: PadLayoutExportCoords]
    let colors: [String: String]
    let strokeColors: [String: String]
}

private struct PadLayoutExportCoords: Codable {
    let x: Double
    let y: Double
    let scale: Double
}
