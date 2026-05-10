// SPDX-License-Identifier: GPL-3.0+

import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Palette

struct ThemeSwatch: Identifiable, Hashable {
    let key: String
    let name: String
    let color: Color
    var id: String { key }
}

// MARK: - Theme manager

@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()


    private let d = UserDefaults.standard


    var accentKey: String { didSet { d.set(accentKey, forKey: Keys.accent) } }

    var colorSchemeKey: String { didSet { d.set(colorSchemeKey, forKey: Keys.colorScheme) } }

    var boxyCorners: Bool { didSet { d.set(boxyCorners, forKey: Keys.boxyCorners) } }

    var glassAccent: Bool { didSet { d.set(glassAccent, forKey: Keys.glassAccent) } }

    var menuTransparency: Double { didSet { d.set(menuTransparency, forKey: Keys.menuTransparency) } }


    var backdropKey: String { didSet { d.set(backdropKey, forKey: Keys.backdropKey) } }

    var bgTintEnabled: Bool { didSet { d.set(bgTintEnabled, forKey: Keys.bgTintEnabled) } }
    var bgTintKey: String { didSet { d.set(bgTintKey, forKey: Keys.bgTintKey) } }
    var bgTintKey2: String { didSet { d.set(bgTintKey2, forKey: Keys.bgTintKey2) } }
    var bgTintStrength: Double { didSet { d.set(bgTintStrength, forKey: Keys.bgTintStrength) } }

    var bgMediaType: String { didSet { d.set(bgMediaType, forKey: Keys.bgMediaType) } }

    var bgMediaFilename: String { didSet { d.set(bgMediaFilename, forKey: Keys.bgMediaFilename) } }

    var bgMediaOpacity: Double { didSet { d.set(bgMediaOpacity, forKey: Keys.bgMediaOpacity) } }

    var fontFamilyKey: String { didSet { d.set(fontFamilyKey, forKey: Keys.fontFamily) } }
    var fontWeightKey: String { didSet { d.set(fontWeightKey, forKey: Keys.fontWeight) } }
    var textScale: Double { didSet { d.set(textScale, forKey: Keys.textScale) } }


    var libraryFontFamilyKey: String { didSet { d.set(libraryFontFamilyKey, forKey: Keys.libraryFontFamily); notifyDeferred("theme.notify.libraryFontFamily") } }
    var libraryFontWeightKey: String { didSet { d.set(libraryFontWeightKey, forKey: Keys.libraryFontWeight); notifyDeferred("theme.notify.libraryFontWeight") } }
    var libraryTextScale: Double { didSet { d.set(libraryTextScale, forKey: Keys.libraryTextScale); notifyDeferred("theme.notify.libraryTextScale") } }
    var libraryTextColorKey: String { didSet { d.set(libraryTextColorKey, forKey: Keys.libraryTextColor); notifyDeferred("theme.notify.libraryTextColor") } }
    var libraryCaptionColorKey: String { didSet { d.set(libraryCaptionColorKey, forKey: Keys.libraryCaptionColor); notifyDeferred("theme.notify.libraryCaptionColor") } }

    var settingsFontFamilyKey: String { didSet { d.set(settingsFontFamilyKey, forKey: Keys.settingsFontFamily); notifyDeferred("theme.notify.settingsFontFamily") } }
    var settingsFontWeightKey: String { didSet { d.set(settingsFontWeightKey, forKey: Keys.settingsFontWeight); notifyDeferred("theme.notify.settingsFontWeight") } }
    var settingsTextScale: Double { didSet { d.set(settingsTextScale, forKey: Keys.settingsTextScale); notifyDeferred("theme.notify.settingsTextScale") } }
    var settingsTextColorKey: String { didSet { d.set(settingsTextColorKey, forKey: Keys.settingsTextColor); notifyDeferred("theme.notify.settingsTextColor") } }
    var settingsCaptionColorKey: String { didSet { d.set(settingsCaptionColorKey, forKey: Keys.settingsCaptionColor); notifyDeferred("theme.notify.settingsCaptionColor") } }

    var topBarFontFamilyKey: String { didSet { d.set(topBarFontFamilyKey, forKey: Keys.topBarFontFamily); notifyDeferred("theme.notify.topBarFontFamily") } }
    var topBarFontWeightKey: String { didSet { d.set(topBarFontWeightKey, forKey: Keys.topBarFontWeight); notifyDeferred("theme.notify.topBarFontWeight") } }
    var topBarTextScale: Double { didSet { d.set(topBarTextScale, forKey: Keys.topBarTextScale); notifyDeferred("theme.notify.topBarTextScale") } }

    var notificationFontFamilyKey: String { didSet { d.set(notificationFontFamilyKey, forKey: Keys.notificationFontFamily); notifyDeferred("theme.notify.notificationFontFamily") } }
    var notificationFontWeightKey: String { didSet { d.set(notificationFontWeightKey, forKey: Keys.notificationFontWeight); notifyDeferred("theme.notify.notificationFontWeight") } }
    var notificationTextScale: Double { didSet { d.set(notificationTextScale, forKey: Keys.notificationTextScale); notifyDeferred("theme.notify.notificationTextScale") } }

    var gridSizeKey: String { didSet { d.set(gridSizeKey, forKey: Keys.gridSize) } }
    var gridSpacing: Double { didSet { d.set(gridSpacing, forKey: Keys.gridSpacing) } }


    var hudColorKey: String { didSet { d.set(hudColorKey, forKey: Keys.hudColor); notifyDeferred("theme.notify.hudTextColor") } }
    var hudLabelColorKey: String { didSet { d.set(hudLabelColorKey, forKey: Keys.hudLabelColor); notifyDeferred("theme.notify.hudLabelColor") } }
    var hudValueColorKey: String { didSet { d.set(hudValueColorKey, forKey: Keys.hudValueColor); notifyDeferred("theme.notify.hudValueColor") } }
    var hudGraphColorKey: String { didSet { d.set(hudGraphColorKey, forKey: Keys.hudGraphColor); notifyDeferred("theme.notify.hudGraphColor") } }
    var hudTileColorKey: String { didSet { d.set(hudTileColorKey, forKey: Keys.hudTileColor); notifyDeferred("theme.notify.hudTileColor") } }
    var hudStrokeColorKey: String { didSet { d.set(hudStrokeColorKey, forKey: Keys.hudStrokeColor); notifyDeferred("theme.notify.hudStrokeColor") } }
    var hudOpacity: Double { didSet { d.set(hudOpacity, forKey: Keys.hudOpacity); notifyDeferred("theme.notify.hudOpacity") } }
    var hudScale: Double { didSet { d.set(hudScale, forKey: Keys.hudScale); notifyDeferred("theme.notify.hudScale") } }
    var hudCornerRadius: Double { didSet { d.set(hudCornerRadius, forKey: Keys.hudCornerRadius); notifyDeferred("theme.notify.hudCornerRadius") } }
    var hudFontFamilyKey: String { didSet { d.set(hudFontFamilyKey, forKey: Keys.hudFontFamily); notifyDeferred("theme.notify.hudFontFamily") } }
    var hudGraphLineWidth: Double { didSet { d.set(hudGraphLineWidth, forKey: Keys.hudGraphLineWidth); notifyDeferred("theme.notify.hudGraphLineWidth") } }


    var vpadColorKey: String { didSet { d.set(vpadColorKey, forKey: Keys.vpadColor); notifyDeferred("theme.notify.vpadColor") } }
    var vpadStrokeColorKey: String { didSet { d.set(vpadStrokeColorKey, forKey: Keys.vpadStrokeColor); notifyDeferred("theme.notify.vpadStrokeColor") } }
    var vpadStrokeWidth: Double { didSet { d.set(vpadStrokeWidth, forKey: Keys.vpadStrokeWidth); notifyDeferred("theme.notify.vpadStrokeWidth") } }

    var inGameMenuUsesLiteChrome: Bool { didSet { d.set(inGameMenuUsesLiteChrome, forKey: Keys.inGameMenuUsesLiteChrome); notifyDeferred("theme.notify.inGameMenuLite") } }
    var inGameMenuScrimOpacity: Double { didSet { d.set(inGameMenuScrimOpacity, forKey: Keys.inGameMenuScrimOpacity); notifyDeferred("theme.notify.inGameMenuDim") } }
    var inGameMenuCornerRadius: Double { didSet { d.set(inGameMenuCornerRadius, forKey: Keys.inGameMenuCornerRadius); notifyDeferred("theme.notify.inGameMenuCorner") } }
    var inGameMenuStrokeOpacity: Double { didSet { d.set(inGameMenuStrokeOpacity, forKey: Keys.inGameMenuStrokeOpacity); notifyDeferred("theme.notify.inGameMenuStrokeOpacity") } }
    var inGameMenuStrokeWidth: Double { didSet { d.set(inGameMenuStrokeWidth, forKey: Keys.inGameMenuStrokeWidth); notifyDeferred("theme.notify.inGameMenuStrokeWidth") } }
    var inGameMenuShadowRadius: Double { didSet { d.set(inGameMenuShadowRadius, forKey: Keys.inGameMenuShadowRadius); notifyDeferred("theme.notify.inGameMenuShadow") } }
    var inGameTopBarOpacity: Double { didSet { d.set(inGameTopBarOpacity, forKey: Keys.inGameTopBarOpacity); notifyDeferred("theme.notify.inGameTopBarOpacity") } }
    var inGameMenuTextColorKey: String { didSet { d.set(inGameMenuTextColorKey, forKey: Keys.inGameMenuText); notifyDeferred("theme.notify.inGameMenuTextColor") } }
    var inGameMenuCaptionColorKey: String { didSet { d.set(inGameMenuCaptionColorKey, forKey: Keys.inGameMenuCaption); notifyDeferred("theme.notify.inGameMenuCaptionColor") } }
    var inGameMenuAccentColorKey: String { didSet { d.set(inGameMenuAccentColorKey, forKey: Keys.inGameMenuAccent); notifyDeferred("theme.notify.inGameMenuAccentColor") } }
    var inGameMenuHeaderColorKey: String { didSet { d.set(inGameMenuHeaderColorKey, forKey: Keys.inGameMenuHeader); notifyDeferred("theme.notify.inGameMenuHeaderColor") } }
    var inGameMenuBubbleColorKey: String { didSet { d.set(inGameMenuBubbleColorKey, forKey: Keys.inGameMenuBubble); notifyDeferred("theme.notify.inGameMenuBubbleColor") } }
    var inGameMenuBubbleFillOpacity: Double { didSet { d.set(inGameMenuBubbleFillOpacity, forKey: Keys.inGameMenuBubbleFill); notifyDeferred("theme.notify.inGameMenuBubbleFill") } }
    var inGameMenuIconColorKey: String { didSet { d.set(inGameMenuIconColorKey, forKey: Keys.inGameMenuIcon); notifyDeferred("theme.notify.inGameMenuIconColor") } }
    var inGameMenuOuterStrokeColorKey: String { didSet { d.set(inGameMenuOuterStrokeColorKey, forKey: Keys.inGameMenuOuterStroke); notifyDeferred("theme.notify.inGameMenuOuterStrokeColor") } }


    var topBarTextColorKey: String { didSet { d.set(topBarTextColorKey, forKey: Keys.topBarText); notifyDeferred("theme.notify.topBarTextColor") } }
    var topBarCaptionColorKey: String { didSet { d.set(topBarCaptionColorKey, forKey: Keys.topBarCaption); notifyDeferred("theme.notify.topBarCaptionColor") } }
    var topBarAccentColorKey: String { didSet { d.set(topBarAccentColorKey, forKey: Keys.topBarAccent); notifyDeferred("theme.notify.topBarAccentColor") } }


    var notificationTintKey: String { didSet { d.set(notificationTintKey, forKey: Keys.notifTint) } }
    var controllerNotificationTintKey: String { didSet { d.set(controllerNotificationTintKey, forKey: Keys.ctrlNotifTint) } }


    var reduceMotion: Bool { didSet { d.set(reduceMotion, forKey: Keys.reduceMotion) } }
    var increaseContrast: Bool { didSet { d.set(increaseContrast, forKey: Keys.increaseContrast) } }
    var differentiateWithoutColor: Bool { didSet { d.set(differentiateWithoutColor, forKey: Keys.differentiateWithoutColor) } }
    var reduceTransparency: Bool { didSet { d.set(reduceTransparency, forKey: Keys.reduceTransparency) } }
    var largerTouchTargets: Bool { didSet { d.set(largerTouchTargets, forKey: Keys.largerTouchTargets) } }
    var highContrastOutlines: Bool { didSet { d.set(highContrastOutlines, forKey: Keys.highContrastOutlines) } }
    var hapticIntensityKey: String { didSet { d.set(hapticIntensityKey, forKey: Keys.hapticIntensity) } }
    var holdToPressMs: Double { didSet { d.set(holdToPressMs, forKey: Keys.holdToPressMs) } }


    private(set) var systemAccessibilityTick: UInt = 0

    var animationsReduced: Bool {
        let _ = systemAccessibilityTick
        return reduceMotion || UIAccessibility.isReduceMotionEnabled
    }

    var materialsReduced: Bool {
        let _ = systemAccessibilityTick
        return reduceTransparency || UIAccessibility.isReduceTransparencyEnabled
    }

    var prefersProMotionUIPacing: Bool {
        UIScreen.main.maximumFramesPerSecond >= 120
    }


    var appIconKey: String { didSet { d.set(appIconKey, forKey: Keys.appIcon) } }

    // MARK: - Init

    private init() {
        func str(_ key: String, _ fallback: String) -> String {
            (UserDefaults.standard.string(forKey: key)?.isEmpty == false
                ? UserDefaults.standard.string(forKey: key)!
                : fallback)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil
                ? fallback
                : UserDefaults.standard.bool(forKey: key)
        }
        func dbl(_ key: String, _ fallback: Double) -> Double {
            UserDefaults.standard.object(forKey: key) == nil
                ? fallback
                : UserDefaults.standard.double(forKey: key)
        }

        accentKey          = str(Keys.accent, "sakura")
        colorSchemeKey     = str(Keys.colorScheme, "dark")
        boxyCorners        = bool(Keys.boxyCorners, false)
        glassAccent        = bool(Keys.glassAccent, true)
        menuTransparency   = dbl(Keys.menuTransparency, 0.6)

        backdropKey        = str(Keys.backdropKey, "sakura")

        bgTintEnabled      = bool(Keys.bgTintEnabled, true)
        bgTintKey          = str(Keys.bgTintKey, "sakuraLight")
        bgTintKey2         = str(Keys.bgTintKey2, "sakuraDark")
        bgTintStrength     = dbl(Keys.bgTintStrength, 0.55)

        bgMediaType        = str(Keys.bgMediaType, "video")
        bgMediaFilename    = str(Keys.bgMediaFilename, Self.cherryBlossomsBackdrop)
        bgMediaOpacity     = dbl(Keys.bgMediaOpacity, 1.0)

        fontFamilyKey      = str(Keys.fontFamily, "rounded")
        fontWeightKey      = str(Keys.fontWeight, "semibold")
        textScale          = dbl(Keys.textScale, 1.0)

        libraryFontFamilyKey = str(Keys.libraryFontFamily, "rounded")
        libraryFontWeightKey = str(Keys.libraryFontWeight, "semibold")
        libraryTextScale     = dbl(Keys.libraryTextScale, 1.0)
        libraryTextColorKey  = str(Keys.libraryTextColor, "white")
        libraryCaptionColorKey = str(Keys.libraryCaptionColor, "white")

        settingsFontFamilyKey = str(Keys.settingsFontFamily, "rounded")
        settingsFontWeightKey = str(Keys.settingsFontWeight, "semibold")
        settingsTextScale     = dbl(Keys.settingsTextScale, 1.0)
        settingsTextColorKey  = str(Keys.settingsTextColor, "white")
        settingsCaptionColorKey = str(Keys.settingsCaptionColor, "white")

        topBarFontFamilyKey = str(Keys.topBarFontFamily, "rounded")
        topBarFontWeightKey = str(Keys.topBarFontWeight, "semibold")
        topBarTextScale     = dbl(Keys.topBarTextScale, 1.0)

        notificationFontFamilyKey = str(Keys.notificationFontFamily, "rounded")
        notificationFontWeightKey = str(Keys.notificationFontWeight, "semibold")
        notificationTextScale     = dbl(Keys.notificationTextScale, 1.0)

        gridSizeKey        = str(Keys.gridSize, "default")
        gridSpacing        = dbl(Keys.gridSpacing, 14)

        hudColorKey        = str(Keys.hudColor, "white")
        hudLabelColorKey   = str(Keys.hudLabelColor, "white")
        hudValueColorKey   = str(Keys.hudValueColor, "white")
        hudGraphColorKey   = str(Keys.hudGraphColor, "blue")
        hudTileColorKey    = str(Keys.hudTileColor, "black")
        hudStrokeColorKey  = str(Keys.hudStrokeColor, "white")
        hudOpacity         = dbl(Keys.hudOpacity, 0.85)
        hudScale           = dbl(Keys.hudScale, 1.0)
        hudCornerRadius    = dbl(Keys.hudCornerRadius, 10)
        hudFontFamilyKey   = str(Keys.hudFontFamily, "mono")
        hudGraphLineWidth  = dbl(Keys.hudGraphLineWidth, 1.2)

        vpadColorKey       = str(Keys.vpadColor, "white")
        vpadStrokeColorKey = str(Keys.vpadStrokeColor, "white")
        vpadStrokeWidth    = dbl(Keys.vpadStrokeWidth, 1.0)

        inGameMenuUsesLiteChrome         = bool(Keys.inGameMenuUsesLiteChrome, true)
        inGameMenuScrimOpacity   = dbl(Keys.inGameMenuScrimOpacity, 0.58)
        inGameMenuCornerRadius = dbl(Keys.inGameMenuCornerRadius, 20)
        inGameMenuStrokeOpacity = dbl(Keys.inGameMenuStrokeOpacity, 0.2)
        inGameMenuStrokeWidth  = dbl(Keys.inGameMenuStrokeWidth, 0.5)
        inGameMenuShadowRadius = dbl(Keys.inGameMenuShadowRadius, 10)
        inGameTopBarOpacity    = dbl(Keys.inGameTopBarOpacity, 0.55)
        inGameMenuTextColorKey    = str(Keys.inGameMenuText, "white")
        inGameMenuCaptionColorKey = str(Keys.inGameMenuCaption, "white")
        inGameMenuAccentColorKey  = str(Keys.inGameMenuAccent, "sakura")
        inGameMenuHeaderColorKey  = str(Keys.inGameMenuHeader, "silver")
        inGameMenuBubbleColorKey  = str(Keys.inGameMenuBubble, "white")
        inGameMenuBubbleFillOpacity = dbl(Keys.inGameMenuBubbleFill, 0.10)
        inGameMenuIconColorKey    = str(Keys.inGameMenuIcon, "white")
        inGameMenuOuterStrokeColorKey = str(Keys.inGameMenuOuterStroke, "silver")

        notificationTintKey            = str(Keys.notifTint, "blue")
        controllerNotificationTintKey  = str(Keys.ctrlNotifTint, "green")

        reduceMotion              = bool(Keys.reduceMotion, false)
        increaseContrast          = bool(Keys.increaseContrast, false)
        differentiateWithoutColor = bool(Keys.differentiateWithoutColor, false)
        reduceTransparency        = bool(Keys.reduceTransparency, false)
        largerTouchTargets        = bool(Keys.largerTouchTargets, false)
        highContrastOutlines      = bool(Keys.highContrastOutlines, false)
        hapticIntensityKey        = str(Keys.hapticIntensity, "medium")
        holdToPressMs             = dbl(Keys.holdToPressMs, 0)

        topBarTextColorKey     = str(Keys.topBarText, "white")
        topBarCaptionColorKey  = str(Keys.topBarCaption, "white")
        topBarAccentColorKey   = str(Keys.topBarAccent, "white")

        appIconKey = str(Keys.appIcon, "default")

        registerAccessibilityStatusObserversIfNeeded()
    }

    @ObservationIgnored private var didRegisterAccessibilityObservers = false

    private func registerAccessibilityStatusObserversIfNeeded() {
        guard !didRegisterAccessibilityObservers else { return }
        didRegisterAccessibilityObservers = true
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main,
            using: { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.systemAccessibilityTick &+= 1
                }
            }
        )
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil,
            queue: .main,
            using: { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.systemAccessibilityTick &+= 1
                }
            }
        )
    }

    // MARK: - Theme change notification

    @ObservationIgnored private var deferredNotifyTimer: Timer?
    @ObservationIgnored private var lastDeferredSubtitleKey: String = ""

    private func notifyDeferred(_ l10nSubtitleKey: String) {
        lastDeferredSubtitleKey = l10nSubtitleKey
        deferredNotifyTimer?.invalidate()
        deferredNotifyTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                SakuraNotificationCenter.shared.post(.themeChanged(setting: self.lastDeferredSubtitleKey))
            }
        }
    }

    // MARK: - Backdrop files

    static let cherryBlossomsBackdrop = "CherryBlossomsBackdrop"

    static func normalizedBackdropFilename(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("bundle:") {
            s = String(s.dropFirst("bundle:".count))
        } else if s.hasPrefix("bundled:") {
            let rest = String(s.dropFirst("bundled:".count))
            s = rest == "DefaultBackdropPixabay268528" ? cherryBlossomsBackdrop : rest
        }
        return s
    }

    static func isCherryBlossomsBackdrop(_ storedFilename: String) -> Bool {
        normalizedBackdropFilename(storedFilename) == cherryBlossomsBackdrop
    }

    static func isUnderBackdropSandbox(_ url: URL) -> Bool {
        url.path.hasPrefix(backgroundMediaDir.path) || url.path.hasPrefix(legacyBackgroundMediaDir.path)
    }

    static var backdropImageFileImporterTypes: [UTType] {
        var t: [UTType] = [.image, .jpeg, .png, .heic, .webP, .gif, .tiff, .data]
        for e in ["bmp", "heif", "jfif"] {
            if let u = UTType(filenameExtension: e) { t.append(u) }
        }
        return t
    }

    static var backdropVideoFileImporterTypes: [UTType] {
        var t: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent, .video]
        for e in ["mp4", "m4v", "mov", "avi", "mkv", "webm", "mpeg", "mpg", "3gp", "wmv", "m2v"] {
            if let u = UTType(filenameExtension: e) { t.append(u) }
        }
        return t
    }

    static func importBackdropFromFilesPicker(_ pickedURL: URL, type: String) throws -> String {
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }

        var ext = pickedURL.pathExtension.lowercased()
        if type == "image" {
            let ok: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "jfif"]
            if ext.isEmpty || !ok.contains(ext) { ext = "jpg" }
        } else {
            let ok: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpeg", "mpg", "3gp", "wmv", "m2v"]
            if ext.isEmpty || !ok.contains(ext) { ext = "mp4" }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        var base = pickedURL.deletingPathExtension().lastPathComponent
        if base.isEmpty { base = "backdrop" }
        let trimmed = String(base.prefix(72)).replacingOccurrences(of: "/", with: "_")
        let safeName = "\(stamp)-\(trimmed).\(ext)"
        let dest = backgroundMediaDir.appendingPathComponent(safeName)
        try FileManager.default.createDirectory(at: backgroundMediaDir, withIntermediateDirectories: true)
        try copySecurityScopedSource(pickedURL, to: dest)
        return safeName
    }

    private static func copySecurityScopedSource(_ src: URL, to dest: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        var blockError: Error?
        let fc = NSFileCoordinator()
        var coordError: NSError?
        fc.coordinate(readingItemAt: src, options: [], error: &coordError) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: dest)
            } catch {
                do {
                    let data = try Data(contentsOf: readURL, options: [.mappedIfSafe])
                    try data.write(to: dest, options: .atomic)
                } catch {
                    blockError = error
                }
            }
        }
        if FileManager.default.fileExists(atPath: dest.path) { return }
        if let blockError { throw blockError }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            let data = try Data(contentsOf: src, options: [.mappedIfSafe])
            try data.write(to: dest, options: .atomic)
        }
    }

    static var backgroundMediaDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var legacyBackgroundMediaDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sakura", isDirectory: true)
            .appendingPathComponent("Backgrounds", isDirectory: true)
    }

    func backgroundMediaURL() -> URL? {
        let name = bgMediaFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let logical = Self.normalizedBackdropFilename(name)

        let docURL = Self.backgroundMediaDir.appendingPathComponent(logical)
        if FileManager.default.fileExists(atPath: docURL.path) { return docURL }
        let legacyURL = Self.legacyBackgroundMediaDir.appendingPathComponent(logical)
        if FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }

        let stem = (logical as NSString).deletingPathExtension
        let ext = (logical as NSString).pathExtension.lowercased()
        let extUse = ext.isEmpty ? "mp4" : ext
        if let u = Bundle.main.url(forResource: stem, withExtension: extUse) { return u }
        if extUse != "mov", let u = Bundle.main.url(forResource: stem, withExtension: "mov") { return u }
        return nil
    }

    // MARK: - Resolvers

    func color(forKey key: String) -> Color {
        Self.palette.first(where: { $0.key == key })?.color ?? .blue
    }

    func accentColor() -> Color { color(forKey: accentKey) }
    func bgTint() -> Color { color(forKey: bgTintKey) }
    func bgTint2() -> Color { color(forKey: bgTintKey2) }

    func bgTintGradient() -> LinearGradient {
        let s = min(max(bgTintStrength, 0), 1)
        return LinearGradient(
            colors: [bgTint().opacity(s), bgTint2().opacity(s)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func splashGradient() -> LinearGradient {
        if increaseContrast {
            return LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.05)], startPoint: .top, endPoint: .bottom)
        }
        switch backdropKey {
        case "whiteout":
            return LinearGradient(
                colors: [Color(red: 0.97, green: 0.96, blue: 0.94), Color(red: 0.85, green: 0.84, blue: 0.82)],
                startPoint: .top, endPoint: .bottom
            )
        case "onyx":
            return LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.09), Color(red: 0.02, green: 0.02, blue: 0.03)],
                startPoint: .top, endPoint: .bottom
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.99, green: 0.82, blue: 0.89), Color(red: 0.45, green: 0.13, blue: 0.30)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
    func hudTextColor() -> Color { color(forKey: hudColorKey) }
    func hudLabelColor() -> Color { color(forKey: hudLabelColorKey) }
    func hudValueColor() -> Color { color(forKey: hudValueColorKey) }
    func hudGraphColor() -> Color { color(forKey: hudGraphColorKey) }
    func hudTileColor() -> Color { color(forKey: hudTileColorKey) }
    func hudStrokeColor() -> Color { color(forKey: hudStrokeColorKey) }
    func topBarTextColor() -> Color { color(forKey: topBarTextColorKey) }
    func topBarCaptionColor() -> Color { color(forKey: topBarCaptionColorKey) }
    func topBarAccentColor() -> Color { color(forKey: topBarAccentColorKey) }
    func topBarControlAccent() -> Color {
        if topBarAccentColorKey == "white" { return accentColor() }
        return topBarAccentColor()
    }

    func inGameMenuTextColor() -> Color { color(forKey: inGameMenuTextColorKey) }
    func inGameMenuCaptionColor() -> Color { color(forKey: inGameMenuCaptionColorKey) }
    func inGameMenuAccentColor() -> Color { color(forKey: inGameMenuAccentColorKey) }

    func inGameMenuControlAccent() -> Color {
        if inGameMenuAccentColorKey == "white" { return accentColor() }
        return inGameMenuAccentColor()
    }

    func inGameMenuHeaderColor() -> Color { color(forKey: inGameMenuHeaderColorKey) }
    func inGameMenuBubbleColor() -> Color { color(forKey: inGameMenuBubbleColorKey) }
    func inGameMenuIconColor() -> Color { color(forKey: inGameMenuIconColorKey) }
    func inGameMenuOuterStrokeColor() -> Color { color(forKey: inGameMenuOuterStrokeColorKey) }

    func notificationTint() -> Color { color(forKey: notificationTintKey) }
    func controllerNotificationTint() -> Color { color(forKey: controllerNotificationTintKey) }

    func glassTextPrimary(_ scheme: ColorScheme) -> Color {
        if increaseContrast { return .white }
        switch scheme {
        case .light: return Color(white: 0.11)
        case .dark:  return .white
        @unknown default: return .white
        }
    }

    func glassTextSecondary(_ scheme: ColorScheme) -> Color {
        if increaseContrast { return .white.opacity(0.8) }
        switch scheme {
        case .light: return Color(white: 0.42)
        case .dark:  return .white.opacity(0.65)
        @unknown default: return .white.opacity(0.65)
        }
    }

    func glassTextTertiary(_ scheme: ColorScheme) -> Color {
        if increaseContrast { return .white.opacity(0.65) }
        switch scheme {
        case .light: return Color(white: 0.52)
        case .dark:  return .white.opacity(0.5)
        @unknown default: return .white.opacity(0.5)
        }
    }

    func glassCardFill(_ scheme: ColorScheme, isFocused: Bool) -> Color {
        let f = isFocused
        if increaseContrast { return .white.opacity(f ? 0.18 : 0.08) }
        switch scheme {
        case .light: return .black.opacity(f ? 0.12 : 0.06)
        case .dark:  return .white.opacity(f ? 0.16 : 0.06)
        @unknown default: return .white.opacity(f ? 0.16 : 0.06)
        }
    }

    func glassCardStroke(_ scheme: ColorScheme, isFocused: Bool) -> Color {
        if isFocused { return glassTextPrimary(scheme) }
        switch scheme {
        case .light: return .black.opacity(0.1)
        case .dark:  return .white.opacity(0.1)
        @unknown default: return .white.opacity(0.1)
        }
    }

    func glassTileBackground(_ scheme: ColorScheme, isFocused: Bool) -> Color {
        if increaseContrast {
            return .white.opacity(isFocused ? 0.18 : 0.10)
        }
        if materialsReduced {
            return .white.opacity(isFocused ? 0.45 : 0.30)
        }
        return glassCardFill(scheme, isFocused: isFocused)
    }

    func glassTileStroke(_ scheme: ColorScheme, isFocused: Bool) -> Color {
        if highContrastOutlines { return isFocused ? .white : .white.opacity(0.5) }
        if increaseContrast { return isFocused ? .white : .white.opacity(0.3) }
        if isFocused { return scheme == .light ? .black.opacity(0.45) : .white }
        return scheme == .light ? .black.opacity(0.12) : .white.opacity(0.12)
    }

    func glassTileShadow(_ scheme: ColorScheme, isFocused: Bool) -> Color {
        if isFocused { return scheme == .light ? .black.opacity(0.18) : .white.opacity(0.2) }
        return .black.opacity(0.3)
    }

    func coverArtStroke(_ scheme: ColorScheme, isSelected: Bool) -> Color {
        if isSelected { return accentColor() }
        return scheme == .light ? .black.opacity(0.12) : .white.opacity(0.08)
    }

    func splashBackgroundColor() -> Color {
        if increaseContrast { return Color(red: 0.05, green: 0.05, blue: 0.05) }
        switch backdropKey {
        case "whiteout": return Color(red: 0.91, green: 0.90, blue: 0.88)
        case "onyx":     return Color(red: 0.04, green: 0.045, blue: 0.05)
        default:         return Color(red: 0.78, green: 0.42, blue: 0.58)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch colorSchemeKey {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var surfaceCornerRadius: CGFloat { boxyCorners ? 6 : 16 }
    var tileCornerRadius: CGFloat { boxyCorners ? 6 : 16 }

    var gridMinTileWidth: CGFloat {
        switch gridSizeKey {
        case "small":  return 130
        case "large":  return 200
        case "xl":     return 240
        default:       return 168
        }
    }

    func fontDesign(for key: String) -> Font.Design {
        switch key {
        case "rounded": return .rounded
        case "serif":   return .serif
        case "mono":    return .monospaced
        default:        return .default
        }
    }

    func fontWeight(for key: String) -> Font.Weight {
        switch key {
        case "regular":  return .regular
        case "medium":   return .medium
        case "bold":     return .bold
        default:         return .semibold
        }
    }

    func fontDesign() -> Font.Design { fontDesign(for: fontFamilyKey) }
    func fontWeight() -> Font.Weight { fontWeight(for: fontWeightKey) }

    func libraryFontDesign() -> Font.Design { fontDesign(for: libraryFontFamilyKey) }
    func libraryFontWeight() -> Font.Weight { fontWeight(for: libraryFontWeightKey) }
    func libraryTextColor() -> Color { color(forKey: libraryTextColorKey) }
    func libraryCaptionColor() -> Color { color(forKey: libraryCaptionColorKey) }

    func settingsFontDesign() -> Font.Design { fontDesign(for: settingsFontFamilyKey) }
    func settingsFontWeight() -> Font.Weight { fontWeight(for: settingsFontWeightKey) }
    func settingsTextColor() -> Color { color(forKey: settingsTextColorKey) }
    func settingsCaptionColor() -> Color { color(forKey: settingsCaptionColorKey) }

    func topBarFontDesign() -> Font.Design { fontDesign(for: topBarFontFamilyKey) }
    func topBarFontWeight() -> Font.Weight { fontWeight(for: topBarFontWeightKey) }

    func notificationFontDesign() -> Font.Design { fontDesign(for: notificationFontFamilyKey) }
    func notificationFontWeight() -> Font.Weight { fontWeight(for: notificationFontWeightKey) }

    func hudFontDesign() -> Font.Design {
        switch hudFontFamilyKey {
        case "rounded": return .rounded
        case "system":  return .default
        default:        return .monospaced
        }
    }

    // MARK: - Reset

    func resetAllToDefaults() {
        for key in Keys.all {
            d.removeObject(forKey: key)
        }
        accentKey = "sakura"
        colorSchemeKey = "dark"
        boxyCorners = false
        glassAccent = true
        menuTransparency = 0.6

        backdropKey = "sakura"

        bgTintEnabled = true
        bgTintKey = "sakuraLight"
        bgTintKey2 = "sakuraDark"
        bgTintStrength = 0.55

        bgMediaType = "video"
        bgMediaFilename = Self.cherryBlossomsBackdrop
        bgMediaOpacity = 1.0

        fontFamilyKey = "rounded"
        fontWeightKey = "semibold"
        textScale = 1.0

        libraryFontFamilyKey = "rounded"
        libraryFontWeightKey = "semibold"
        libraryTextScale = 1.0
        libraryTextColorKey = "white"
        libraryCaptionColorKey = "white"

        settingsFontFamilyKey = "rounded"
        settingsFontWeightKey = "semibold"
        settingsTextScale = 1.0
        settingsTextColorKey = "white"
        settingsCaptionColorKey = "white"

        topBarFontFamilyKey = "rounded"
        topBarFontWeightKey = "semibold"
        topBarTextScale = 1.0

        notificationFontFamilyKey = "rounded"
        notificationFontWeightKey = "semibold"
        notificationTextScale = 1.0

        gridSizeKey = "default"
        gridSpacing = 14

        hudColorKey = "white"
        hudLabelColorKey = "white"
        hudValueColorKey = "white"
        hudGraphColorKey = "blue"
        hudTileColorKey = "black"
        hudStrokeColorKey = "white"
        hudOpacity = 0.85
        hudScale = 1.0
        hudCornerRadius = 10
        hudFontFamilyKey = "mono"
        hudGraphLineWidth = 1.2

        vpadColorKey = "white"
        vpadStrokeColorKey = "white"
        vpadStrokeWidth = 1.0

        inGameMenuUsesLiteChrome = true
        inGameMenuScrimOpacity = 0.58
        inGameMenuCornerRadius = 20
        inGameMenuStrokeOpacity = 0.2
        inGameMenuStrokeWidth = 0.5
        inGameMenuShadowRadius = 10
        inGameTopBarOpacity = 0.55
        inGameMenuTextColorKey = "white"
        inGameMenuCaptionColorKey = "white"
        inGameMenuAccentColorKey = "sakura"
        inGameMenuHeaderColorKey = "silver"
        inGameMenuBubbleColorKey = "white"
        inGameMenuBubbleFillOpacity = 0.10
        inGameMenuIconColorKey = "white"
        inGameMenuOuterStrokeColorKey = "silver"

        notificationTintKey = "blue"
        controllerNotificationTintKey = "green"

        reduceMotion = false
        increaseContrast = false
        differentiateWithoutColor = false
        reduceTransparency = false
        largerTouchTargets = false
        highContrastOutlines = false
        hapticIntensityKey = "medium"
        holdToPressMs = 0

        topBarTextColorKey     = "white"
        topBarCaptionColorKey  = "white"
        topBarAccentColorKey   = "white"

        appIconKey = "default"
    }

    // MARK: - Swatches

    nonisolated static let palette: [ThemeSwatch] = [
        .init(key: "sakura",      name: "Sakura",      color: Color(red: 0.96, green: 0.55, blue: 0.78)),
        .init(key: "sakuraLight", name: "Sakura Light", color: Color(red: 0.99, green: 0.83, blue: 0.90)),
        .init(key: "sakuraDark",  name: "Sakura Dark",  color: Color(red: 0.55, green: 0.18, blue: 0.38)),
        .init(key: "blue",        name: "Blue",        color: Color(red: 0.10, green: 0.45, blue: 0.95)),
        .init(key: "indigo",      name: "Indigo",      color: Color(red: 0.30, green: 0.30, blue: 0.85)),
        .init(key: "purple",      name: "Purple",      color: Color(red: 0.55, green: 0.35, blue: 0.90)),
        .init(key: "violet",      name: "Violet",      color: Color(red: 0.70, green: 0.40, blue: 0.95)),
        .init(key: "pink",        name: "Pink",        color: Color(red: 0.97, green: 0.40, blue: 0.70)),
        .init(key: "rose",        name: "Rose",        color: Color(red: 0.98, green: 0.50, blue: 0.60)),
        .init(key: "red",         name: "Red",         color: Color(red: 0.95, green: 0.30, blue: 0.30)),
        .init(key: "garnet",      name: "Garnet",      color: Color(red: 0.70, green: 0.15, blue: 0.25)),
        .init(key: "orange",      name: "Orange",      color: Color(red: 0.99, green: 0.55, blue: 0.20)),
        .init(key: "amber",       name: "Amber",       color: Color(red: 0.97, green: 0.75, blue: 0.18)),
        .init(key: "yellow",      name: "Yellow",      color: Color(red: 0.98, green: 0.88, blue: 0.25)),
        .init(key: "lime",        name: "Lime",        color: Color(red: 0.70, green: 0.90, blue: 0.25)),
        .init(key: "green",       name: "Green",       color: Color(red: 0.28, green: 0.80, blue: 0.38)),
        .init(key: "emerald",     name: "Emerald",     color: Color(red: 0.15, green: 0.70, blue: 0.55)),
        .init(key: "teal",        name: "Teal",        color: Color(red: 0.20, green: 0.70, blue: 0.75)),
        .init(key: "cyan",        name: "Cyan",        color: Color(red: 0.25, green: 0.78, blue: 0.95)),
        .init(key: "sky",         name: "Sky",         color: Color(red: 0.35, green: 0.70, blue: 0.99)),
        .init(key: "navy",        name: "Navy",        color: Color(red: 0.10, green: 0.20, blue: 0.55)),
        .init(key: "ocean",       name: "Ocean",       color: Color(red: 0.05, green: 0.40, blue: 0.55)),
        .init(key: "mint",        name: "Mint",        color: Color(red: 0.55, green: 0.92, blue: 0.75)),
        .init(key: "sage",        name: "Sage",        color: Color(red: 0.60, green: 0.75, blue: 0.60)),
        .init(key: "olive",       name: "Olive",       color: Color(red: 0.55, green: 0.55, blue: 0.30)),
        .init(key: "brown",       name: "Brown",       color: Color(red: 0.55, green: 0.40, blue: 0.25)),
        .init(key: "tan",         name: "Tan",         color: Color(red: 0.80, green: 0.70, blue: 0.55)),
        .init(key: "beige",       name: "Beige",       color: Color(red: 0.90, green: 0.85, blue: 0.70)),
        .init(key: "cream",       name: "Cream",       color: Color(red: 0.98, green: 0.95, blue: 0.85)),
        .init(key: "white",       name: "White",       color: .white),
        .init(key: "silver",      name: "Silver",      color: Color(white: 0.80)),
        .init(key: "gray",        name: "Gray",        color: Color(white: 0.55)),
        .init(key: "charcoal",    name: "Charcoal",    color: Color(white: 0.30)),
        .init(key: "black",       name: "Black",       color: .black),
        .init(key: "magenta",     name: "Magenta",     color: Color(red: 0.92, green: 0.25, blue: 0.85)),
        .init(key: "coral",       name: "Coral",       color: Color(red: 0.99, green: 0.50, blue: 0.45)),
        .init(key: "peach",       name: "Peach",       color: Color(red: 0.99, green: 0.75, blue: 0.60)),
        .init(key: "lavender",    name: "Lavender",    color: Color(red: 0.75, green: 0.70, blue: 0.92)),
        .init(key: "turquoise",   name: "Turquoise",   color: Color(red: 0.18, green: 0.80, blue: 0.75)),
        .init(key: "gold",        name: "Gold",        color: Color(red: 0.90, green: 0.75, blue: 0.30)),
        .init(key: "bronze",      name: "Bronze",      color: Color(red: 0.70, green: 0.50, blue: 0.30)),
        .init(key: "plum",        name: "Plum",        color: Color(red: 0.55, green: 0.30, blue: 0.50)),
        .init(key: "maroon",      name: "Maroon",      color: Color(red: 0.50, green: 0.10, blue: 0.20)),
    ]

    // MARK: - UserDefaults keys

    private enum Keys {
        static let accent = "sakura.theme.accent"
        static let colorScheme = "sakura.theme.colorScheme"
        static let boxyCorners = "sakura.theme.boxyCorners"
        static let glassAccent = "sakura.theme.glassAccent"
        static let menuTransparency = "sakura.theme.menuTransparency"

        static let backdropKey = "sakura.theme.backdropKey"

        static let bgTintEnabled = "sakura.theme.bgTintEnabled"
        static let bgTintKey = "sakura.theme.bgTintKey"
        static let bgTintKey2 = "sakura.theme.bgTintKey2"
        static let bgTintStrength = "sakura.theme.bgTintStrength"

        static let bgMediaType = "sakura.theme.bgMediaType"
        static let bgMediaFilename = "sakura.theme.bgMediaFilename"
        static let bgMediaOpacity = "sakura.theme.bgMediaOpacity"

        static let fontFamily = "sakura.theme.fontFamily"
        static let fontWeight = "sakura.theme.fontWeight"
        static let textScale = "sakura.theme.textScale"

        static let libraryFontFamily = "sakura.theme.libraryFontFamily"
        static let libraryFontWeight = "sakura.theme.libraryFontWeight"
        static let libraryTextScale = "sakura.theme.libraryTextScale"
        static let libraryTextColor = "sakura.theme.libraryTextColor"
        static let libraryCaptionColor = "sakura.theme.libraryCaptionColor"

        static let settingsFontFamily = "sakura.theme.settingsFontFamily"
        static let settingsFontWeight = "sakura.theme.settingsFontWeight"
        static let settingsTextScale = "sakura.theme.settingsTextScale"
        static let settingsTextColor = "sakura.theme.settingsTextColor"
        static let settingsCaptionColor = "sakura.theme.settingsCaptionColor"

        static let topBarFontFamily = "sakura.theme.topBarFontFamily"
        static let topBarFontWeight = "sakura.theme.topBarFontWeight"
        static let topBarTextScale = "sakura.theme.topBarTextScale"

        static let notificationFontFamily = "sakura.theme.notificationFontFamily"
        static let notificationFontWeight = "sakura.theme.notificationFontWeight"
        static let notificationTextScale = "sakura.theme.notificationTextScale"

        static let gridSize = "sakura.theme.gridSize"
        static let gridSpacing = "sakura.theme.gridSpacing"

        static let hudColor = "sakura.theme.hudColor"
        static let hudLabelColor = "sakura.theme.hudLabelColor"
        static let hudValueColor = "sakura.theme.hudValueColor"
        static let hudGraphColor = "sakura.theme.hudGraphColor"
        static let hudTileColor = "sakura.theme.hudTileColor"
        static let hudStrokeColor = "sakura.theme.hudStrokeColor"
        static let hudOpacity = "sakura.theme.hudOpacity"
        static let hudScale = "sakura.theme.hudScale"
        static let hudCornerRadius = "sakura.theme.hudCornerRadius"
        static let hudFontFamily = "sakura.theme.hudFontFamily"
        static let hudGraphLineWidth = "sakura.theme.hudGraphLineWidth"

        static let vpadColor = "sakura.theme.vpadColor"
        static let vpadStrokeColor = "sakura.theme.vpadStrokeColor"
        static let vpadStrokeWidth = "sakura.theme.vpadStrokeWidth"

        static let inGameMenuUsesLiteChrome = "sakura.emuMenu.lite"
        static let inGameMenuScrimOpacity = "sakura.emuMenu.dimOpacity"
        static let inGameMenuCornerRadius = "sakura.emuMenu.cornerRadius"
        static let inGameMenuStrokeOpacity = "sakura.emuMenu.strokeOpacity"
        static let inGameMenuStrokeWidth = "sakura.emuMenu.strokeWidth"
        static let inGameMenuShadowRadius = "sakura.emuMenu.shadowRadius"
        static let inGameTopBarOpacity = "sakura.emuTopBarOpacity"
        static let inGameMenuText = "sakura.emuMenu.text"
        static let inGameMenuCaption = "sakura.emuMenu.caption"
        static let inGameMenuAccent = "sakura.emuMenu.accent"
        static let inGameMenuHeader = "sakura.emuMenu.headerColor"
        static let inGameMenuBubble = "sakura.emuMenu.bubbleColor"
        static let inGameMenuBubbleFill = "sakura.emuMenu.bubbleFillOpacity"
        static let inGameMenuIcon = "sakura.emuMenu.iconColor"
        static let inGameMenuOuterStroke = "sakura.emuMenu.outerStrokeColor"

        static let topBarText     = "sakura.theme.topBarText"
        static let topBarCaption  = "sakura.theme.topBarCaption"
        static let topBarAccent   = "sakura.theme.topBarAccent"

        static let notifTint = "sakura.theme.notifTint"
        static let ctrlNotifTint = "sakura.theme.ctrlNotifTint"

        static let reduceMotion = "sakura.theme.reduceMotion"
        static let increaseContrast = "sakura.theme.increaseContrast"
        static let differentiateWithoutColor = "sakura.theme.differentiateWithoutColor"
        static let reduceTransparency = "sakura.theme.reduceTransparency"
        static let largerTouchTargets = "sakura.theme.largerTouchTargets"
        static let highContrastOutlines = "sakura.theme.highContrastOutlines"
        static let hapticIntensity = "sakura.theme.hapticIntensity"
        static let holdToPressMs = "sakura.theme.holdToPressMs"

        static let appIcon = "sakura.theme.appIcon"

        static let all: [String] = [
            accent, colorScheme, boxyCorners, glassAccent, menuTransparency,
            backdropKey,
            bgTintEnabled, bgTintKey, bgTintKey2, bgTintStrength,
            bgMediaType, bgMediaFilename, bgMediaOpacity,
            fontFamily, fontWeight, textScale,
            libraryFontFamily, libraryFontWeight, libraryTextScale, libraryTextColor, libraryCaptionColor,
            settingsFontFamily, settingsFontWeight, settingsTextScale, settingsTextColor, settingsCaptionColor,
            topBarFontFamily, topBarFontWeight, topBarTextScale,
            notificationFontFamily, notificationFontWeight, notificationTextScale,
            gridSize, gridSpacing,
            hudColor, hudLabelColor, hudValueColor, hudGraphColor,
            hudTileColor, hudStrokeColor, hudOpacity, hudScale,
            hudCornerRadius, hudFontFamily, hudGraphLineWidth,
            vpadColor, vpadStrokeColor, vpadStrokeWidth,
            topBarText, topBarCaption, topBarAccent,
            inGameMenuUsesLiteChrome, inGameMenuScrimOpacity, inGameMenuCornerRadius,
            inGameMenuStrokeOpacity, inGameMenuStrokeWidth, inGameMenuShadowRadius,
            inGameTopBarOpacity, inGameMenuText, inGameMenuCaption, inGameMenuAccent,
            inGameMenuHeader, inGameMenuBubble, inGameMenuBubbleFill, inGameMenuIcon, inGameMenuOuterStroke,
            notifTint, ctrlNotifTint,
            reduceMotion, increaseContrast, differentiateWithoutColor,
            reduceTransparency, largerTouchTargets, highContrastOutlines,
            hapticIntensity, holdToPressMs,
            appIcon,
        ]
    }
}

extension ThemeManager {
    var emuMenuPresentAnimation: Animation {
        if animationsReduced {
            .linear(duration: 0.05)
        } else if prefersProMotionUIPacing {
            .spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.08)
        } else {
            .spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.12)
        }
    }

    var emuMenuSmoothAnimation: Animation {
        if animationsReduced {
            .easeOut(duration: 0.1)
        } else if prefersProMotionUIPacing {
            Animation.smooth(duration: 0.17)
        } else {
            .easeInOut(duration: 0.22)
        }
    }

    var emuMenuScrollFocusAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.08) : .easeInOut(duration: prefersProMotionUIPacing ? 0.14 : 0.18)
    }

    var layoutEditSpringAnimation: Animation {
        if animationsReduced {
            .easeOut(duration: 0.1)
        } else if prefersProMotionUIPacing {
            .spring(response: 0.24, dampingFraction: 0.82)
        } else {
            .spring(response: 0.3, dampingFraction: 0.8)
        }
    }

    var shellOverlayDismissAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.12) : .easeOut(duration: prefersProMotionUIPacing ? 0.26 : 0.34)
    }

    var onboardingPageTransitionAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.25)
    }

    var onboardingDotsAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.08)
            : .spring(response: prefersProMotionUIPacing ? 0.28 : 0.35, dampingFraction: 0.82)
    }

    var helpAccordionAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.18)
    }

    var libraryCarouselSelectAnimation: Animation {
        layoutEditSpringAnimation
    }

    var libraryCarouselScrollAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.1) : .easeInOut(duration: prefersProMotionUIPacing ? 0.14 : 0.2)
    }

    var libraryCardScaleAnimation: Animation {
        if animationsReduced {
            return .easeOut(duration: 0.04)
        }
        return .spring(response: prefersProMotionUIPacing ? 0.26 : 0.3, dampingFraction: 0.72)
    }

    var stickSnapBackAnimation: Animation {
        if animationsReduced {
            return .easeOut(duration: 0.08)
        }
        if prefersProMotionUIPacing {
            return .spring(response: 0.26, dampingFraction: 0.55)
        }
        return .spring(response: 0.3, dampingFraction: 0.5)
    }

    var notificationDismissThrowAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.02) : .easeOut(duration: 0.2)
    }

    var notificationGestureSnapAnimation: Animation {
        animationsReduced ? .easeOut(duration: 0.08) : .spring(response: prefersProMotionUIPacing ? 0.26 : 0.3, dampingFraction: 0.6)
    }
}
