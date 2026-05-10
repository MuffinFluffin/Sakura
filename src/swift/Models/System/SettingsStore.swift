// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

extension Notification.Name {
    static let sakuraSecondaryGameplayChromeRefresh = Notification.Name("sakura.secondaryGameplay.chromeRefresh")
}

@Observable
final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()

    private static func liveApply() {
        SakuraBridge.applyEmulatorSettings()
    }

    private static func currentAspectRatioIndex() -> Int {
        SakuraBridge.getINIString("EmuCore/GS", key: "AspectRatio", defaultValue: "4:3") == "Fill" ? 3 : 2
    }

    var fastBoot: Bool {
        didSet { SakuraBridge.setINIBool("GameISO", key: "FastBoot", value: fastBoot); Self.liveApply() }
    }

    static let upscaleTiers: [Float] = [1, 1.25, 1.5, 1.75, 2, 4, 8, 16]

    static let upscaleMultiplierOptions: [(value: Float, label: String)] = upscaleTiers.map { v in
        let lab: String
        switch v {
        case 1: lab = "1x"
        case 1.25: lab = "1.25x"
        case 1.5: lab = "1.5x"
        case 1.75: lab = "1.75x"
        default: lab = "\(Int(v))x"
        }
        return (v, lab)
    }

    private static func normalizeUpscaleFromINI(_ raw: Float) -> Float {
        for t in upscaleTiers {
            if abs(t - raw) < 0.031 { return t }
        }
        return upscaleTiers.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1
    }

    var upscaleMultiplier: Float {
        didSet {
            let coerced = Self.normalizeUpscaleFromINI(upscaleMultiplier)
            if coerced != upscaleMultiplier {
                upscaleMultiplier = coerced
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "upscale_multiplier", value: upscaleMultiplier)
            NotificationCenter.default.post(name: .sakuraUpscaleMultiplierChanged, object: nil)
            Self.liveApply()
        }
    }
    static let textureFilteringOptions: [(value: Int, label: String)] = [
        (0, "Nearest"),
        (1, "Bilinear"),
        (2, "3-Point"),
        (3, "SABR"),
        (4, "xBR"),
        (5, "xBRZ"),
        (6, "FSR 1"),
        (7, "Anime4K"),
    ]
    var textureFiltering: Int {
        didSet {
            let clamped = max(0, min(7, textureFiltering))
            if clamped != textureFiltering {
                textureFiltering = clamped
                return
            }
            SakuraBridge.setINIInt("EmuCore/GS", key: "filter", value: Int32(textureFiltering)); Self.liveApply()
        }
    }
    var fxaa: Bool {
        didSet { SakuraBridge.setINIBool("EmuCore/GS", key: "fxaa", value: fxaa); Self.liveApply() }
    }
    // SMAA, Subpixel Morphological Antialiasing. 0 = Off, 1..4 = Low/Medium/High/Ultra. independent of FXAA.
    var smaaQuality: Int {
        didSet {
            let q = max(0, min(4, smaaQuality))
            SakuraBridge.setINIInt("EmuCore/GS", key: "smaa_quality", value: Int32(q))
            Self.liveApply()
        }
    }
    var smaaLinearSpace: Bool {
        didSet { SakuraBridge.setINIBool("EmuCore/GS", key: "smaa_linear", value: smaaLinearSpace); Self.liveApply() }
    }
    var smaaAdaptiveThreshold: Bool {
        didSet { SakuraBridge.setINIBool("EmuCore/GS", key: "smaa_adaptive", value: smaaAdaptiveThreshold); Self.liveApply() }
    }
    var smaaPixelArtMode: Bool {
        didSet { SakuraBridge.setINIBool("EmuCore/GS", key: "smaa_pixel_art", value: smaaPixelArtMode); Self.liveApply() }
    }
    var smaaThresholdScale: Float {
        didSet {
            let v = min(max(smaaThresholdScale, 0.1), 4.0)
            SakuraBridge.setINIFloat("EmuCore/GS", key: "smaa_threshold_scale", value: v)
            Self.liveApply()
        }
    }
    var smaaPixelArtTolerance: Float {
        didSet {
            let v = min(max(smaaPixelArtTolerance, 0.001), 0.2)
            SakuraBridge.setINIFloat("EmuCore/GS", key: "smaa_pixel_art_tol", value: v)
            Self.liveApply()
        }
    }
    var displayColorSaturation: Float {
        didSet {
            let s = PresentationColor.clampUniform(displayColorSaturation)
            if s != displayColorSaturation {
                displayColorSaturation = s
                return
            }
            SakuraBridge.setINIFloat(
                "EmuCore/GS",
                key: "display_color_saturation",
                value: PresentationColor.iniDisplayColorSaturation(fromUniform: s)
            )
            Self.liveApply()
        }
    }

    var colorAdjustEnabled: Bool = false {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "color_adjust_enabled", value: colorAdjustEnabled)
            Self.liveApply()
        }
    }

    var colorAdjustBrightness: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustBrightness)
            if c != colorAdjustBrightness {
                colorAdjustBrightness = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_brightness", value: PresentationColor.iniBrightness(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustContrast: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustContrast)
            if c != colorAdjustContrast {
                colorAdjustContrast = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_contrast", value: PresentationColor.iniContrast(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustVibrance: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustVibrance)
            if c != colorAdjustVibrance {
                colorAdjustVibrance = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_vibrance", value: PresentationColor.iniVibrance(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustExposure: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustExposure)
            if c != colorAdjustExposure {
                colorAdjustExposure = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_exposure", value: PresentationColor.iniExposure(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustGamma: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustGamma)
            if c != colorAdjustGamma {
                colorAdjustGamma = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_gamma", value: PresentationColor.iniGamma(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustColorTemperature: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustColorTemperature)
            if c != colorAdjustColorTemperature {
                colorAdjustColorTemperature = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_temperature", value: PresentationColor.iniColorTemperature(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustSharpness: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustSharpness)
            if c != colorAdjustSharpness {
                colorAdjustSharpness = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_sharpness", value: PresentationColor.iniSharpness(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustBloom: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustBloom)
            if c != colorAdjustBloom {
                colorAdjustBloom = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_bloom", value: PresentationColor.iniBloomIntensity(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustBloomRadius: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustBloomRadius)
            if c != colorAdjustBloomRadius {
                colorAdjustBloomRadius = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_bloom_radius", value: PresentationColor.iniBloomRadius(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustVignette: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustVignette)
            if c != colorAdjustVignette {
                colorAdjustVignette = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_vignette", value: PresentationColor.iniVignetteIntensity(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustVignetteRadius: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustVignetteRadius)
            if c != colorAdjustVignetteRadius {
                colorAdjustVignetteRadius = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_vignette_radius", value: PresentationColor.iniVignetteRadius(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustHdrEnabled: Bool = false {
        didSet {
            if colorAdjustHdrEnabled, !PresentationColor.extendedBrightnessAvailable {
                colorAdjustHdrEnabled = false
                return
            }
            SakuraBridge.setINIBool("EmuCore/GS", key: "color_adjust_hdr_enabled", value: colorAdjustHdrEnabled)
            Self.liveApply()
        }
    }

    var colorAdjustHdrExposure: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustHdrExposure)
            if c != colorAdjustHdrExposure {
                colorAdjustHdrExposure = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_hdr_exposure", value: PresentationColor.iniHdrExposure(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustHdrSaturation: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustHdrSaturation)
            if c != colorAdjustHdrSaturation {
                colorAdjustHdrSaturation = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_hdr_saturation", value: PresentationColor.iniHdrSaturation(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustHdrContrast: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustHdrContrast)
            if c != colorAdjustHdrContrast {
                colorAdjustHdrContrast = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_hdr_contrast", value: PresentationColor.iniHdrContrast(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustHdrBloom: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustHdrBloom)
            if c != colorAdjustHdrBloom {
                colorAdjustHdrBloom = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_hdr_bloom", value: PresentationColor.iniHdrBloom(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustHdrShadowLift: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustHdrShadowLift)
            if c != colorAdjustHdrShadowLift {
                colorAdjustHdrShadowLift = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_hdr_shadow_lift", value: PresentationColor.iniHdrShadowLift(fromUniform: c))
            Self.liveApply()
        }
    }

    var colorAdjustHdrHighlightCompress: Float = PresentationColor.uniformSliderDefault {
        didSet {
            let c = PresentationColor.clampUniform(colorAdjustHdrHighlightCompress)
            if c != colorAdjustHdrHighlightCompress {
                colorAdjustHdrHighlightCompress = c
                return
            }
            SakuraBridge.setINIFloat("EmuCore/GS", key: "color_adjust_hdr_highlight_compress", value: PresentationColor.iniHdrHighlightCompress(fromUniform: c))
            Self.liveApply()
        }
    }

    var metalFXTexture: Bool {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "metalfx_texture", value: metalFXTexture)
            Self.liveApply()
        }
    }
    var metalFXTemporalDisplay: Bool {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "metalfx_temporal_display", value: metalFXTemporalDisplay)
            Self.liveApply()
        }
    }
    var mainThreadMetalPresentEnabled: Bool {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "split_present", value: mainThreadMetalPresentEnabled)
            NotificationCenter.default.post(name: .sakuraMainThreadMetalPresentChanged, object: nil)
            Self.liveApply()
        }
    }
    var videotoolboxFrameFeatures: Bool {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "videotoolbox_ios26_frame_features", value: videotoolboxFrameFeatures)
            Self.liveApply()
        }
    }
    var metalFXFrameInterpolation: Bool {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "metalfx_frame_interpolation", value: metalFXFrameInterpolation)
            Self.liveApply()
        }
    }

    var neuralUpscaleLive: Bool = false {
        didSet { SakuraBridge.setINIBool("EmuCore/GS", key: "neural_upscale_live", value: neuralUpscaleLive); Self.liveApply() }
    }

    var neuralUpscaleTextureArt: Bool = false {
        didSet {
            SakuraBridge.setINIBool("EmuCore/GS", key: "neural_upscale_texture_art", value: neuralUpscaleTextureArt)
            Self.liveApply()
            if neuralUpscaleTextureArt {
                SakuraBridge.warmUpNeuralModelAsync()
            }
        }
    }

    var neuralUpscaleModelToken: String = NeuralUpscaleRegistry.bundledINIValue {
        didSet {
            let coerced = Self.coerceNeuralModelToken(neuralUpscaleModelToken)
            if coerced != neuralUpscaleModelToken {
                neuralUpscaleModelToken = coerced
                return
            }
            SakuraBridge.setINIString("EmuCore/GS", key: "neural_upscale_model", value: neuralUpscaleModelToken)
            Self.liveApply()
            if oldValue != neuralUpscaleModelToken {
                // different model = stale upscaled covers; regenerate lazily on next render
                GameCoverUpscaler.shared.invalidateAllUpscaledCovers(in: GameMetadataService.shared.coversDir)
                if neuralUpscaleLive || neuralUpscaleTextureArt {
                    SakuraBridge.warmUpNeuralModelAsync()
                }
            }
        }
    }

    var casMode: Int {
        didSet { SakuraBridge.setINIInt("EmuCore/GS", key: "CASMode", value: Int32(casMode)); Self.liveApply() }
    }
    var casSharpness: Int {
        didSet {
            let c = max(0, min(100, casSharpness))
            if c != casSharpness {
                casSharpness = c
                return
            }
            SakuraBridge.setINIInt("EmuCore/GS", key: "CASSharpness", value: Int32(casSharpness)); Self.liveApply()
        }
    }
    var aspectRatio: Int {
        didSet {
            let m = aspectRatio == 3 ? 3 : 2
            if aspectRatio != m {
                aspectRatio = m
                return
            }
            SakuraBridge.setINIString("EmuCore/GS", key: "AspectRatio", value: m == 3 ? "Fill" : "4:3")
            SakuraBridge.setHostPresentAspectMode(Int32(m))
            Self.liveApply()
        }
    }
    var nativeScaleMetalDrawable: Bool {
        didSet {
            SakuraBridge.setINIInt("EmuCore/GS", key: "Renderer", value: nativeScaleMetalDrawable ? 14 : 17)
            NotificationCenter.default.post(name: .sakuraNativeScaleDrawableChanged, object: nil)
        }
    }

    var hudEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(hudEnabled, forKey: "sakura.hud.enabled")
            NotificationCenter.default.post(name: .sakuraSecondaryGameplayChromeRefresh, object: nil)
        }
    }
    var hudRefreshRate: Int = 6 {
        didSet {
            UserDefaults.standard.set(hudRefreshRate, forKey: "sakura.hud.refreshRate")
            Task { @MainActor in HUDModel.shared.refreshRate = hudRefreshRate }
        }
    }
    var hudShowFPS: Bool = true              { didSet { UserDefaults.standard.set(hudShowFPS, forKey: "sakura.hud.show.fps") } }
    var hudShowSpeed: Bool = true            { didSet { UserDefaults.standard.set(hudShowSpeed, forKey: "sakura.hud.show.speed") } }
    var hudShowAvgLow: Bool = true           { didSet { UserDefaults.standard.set(hudShowAvgLow, forKey: "sakura.hud.show.avgLow") } }
    var hudShowFrameTime: Bool = true        { didSet { UserDefaults.standard.set(hudShowFrameTime, forKey: "sakura.hud.show.frameTime") } }
    var hudShowCPU: Bool = true              { didSet { UserDefaults.standard.set(hudShowCPU, forKey: "sakura.hud.show.cpu") } }
    var hudShowRAM: Bool = true              { didSet { UserDefaults.standard.set(hudShowRAM, forKey: "sakura.hud.show.ram") } }
    var hudShowGPU: Bool = true              { didSet { UserDefaults.standard.set(hudShowGPU, forKey: "sakura.hud.show.gpu") } }
    var hudShowResolution: Bool = true      { didSet { UserDefaults.standard.set(hudShowResolution, forKey: "sakura.hud.show.resolution") } }
    var hudShowTemperature: Bool = true      { didSet { UserDefaults.standard.set(hudShowTemperature, forKey: "sakura.hud.show.thermal") } }
    var hudShowBattery: Bool = true          { didSet { UserDefaults.standard.set(hudShowBattery, forKey: "sakura.hud.show.battery") } }
    var hudShowGraphs: Bool = true           { didSet { UserDefaults.standard.set(hudShowGraphs, forKey: "sakura.hud.show.graphs") } }

    var topBarHideBattery: Bool  = false { didSet { UserDefaults.standard.set(topBarHideBattery, forKey: "sakura.topbar.hideBattery") } }
    var topBarHideMusic: Bool    = true  { didSet { UserDefaults.standard.set(topBarHideMusic, forKey: "sakura.topbar.hideMusic") } }
    var bottomActionBarHidden: Bool = false { didSet { UserDefaults.standard.set(bottomActionBarHidden, forKey: "sakura.library.bottomBarHidden") } }

    var saveStatesEnabled: Bool = true { didSet { UserDefaults.standard.set(saveStatesEnabled, forKey: "sakura.savestates.enabled") } }

    var padOpacity: Float {
        didSet { SakuraBridge.setINIFloat("Sakura/UI", key: "PadOpacity", value: padOpacity) }
    }
    var pauseOnMenuEnabled: Bool {
        didSet { SakuraBridge.setINIBool("Sakura/UI", key: "PauseOnMenu", value: pauseOnMenuEnabled) }
    }

    var emuMenuKeepSubmenusOpen: Bool = false {
        didSet { UserDefaults.standard.set(emuMenuKeepSubmenusOpen, forKey: "Sakura/EmulationMenu/keepSubmenusOpen") }
    }
    var emuMenuPreventScreenSleep: Bool = true {
        didSet { UserDefaults.standard.set(emuMenuPreventScreenSleep, forKey: "Sakura/EmulationMenu/preventScreenSleep") }
    }
    var emuMenuAutoHideBarRaw: String = AutoHideBarOption.off.rawValue {
        didSet {
            UserDefaults.standard.set(emuMenuAutoHideBarRaw, forKey: "Sakura/EmulationMenu/autoHideBarOption")
            UserDefaults.standard.set(emuMenuAutoHideBarRaw, forKey: "AutoHideBarOption")
        }
    }
    var emuMenuConfirmOnStop: Bool = true {
        didSet { UserDefaults.standard.set(emuMenuConfirmOnStop, forKey: "sakura.emuMenu.confirmOnStop") }
    }

    var hapticFeedback: Bool {
        didSet { SakuraBridge.setINIBool("Sakura/UI", key: "HapticFeedback", value: hapticFeedback) }
    }
    var controllerAutoSwitch: Bool {
        didSet { SakuraBridge.setINIBool("Controller", key: "AutoSwitch", value: controllerAutoSwitch); Self.liveApply() }
    }

    var controllerRumbleEnabled: Bool {
        didSet { SakuraBridge.setINIBool("Sakura/UI", key: "ControllerRumble", value: controllerRumbleEnabled) }
    }
    var controllerRumbleIntensity: Float {
        didSet { SakuraBridge.setINIFloat("Sakura/UI", key: "ControllerRumbleIntensity", value: controllerRumbleIntensity) }
    }
    
    var controllerPortAssignmentsRaw: String {
        didSet { SakuraBridge.setINIString("Controller", key: "PortAssignments", value: controllerPortAssignmentsRaw) }
    }
    var phoneVibrationFallback: Bool {
        didSet { SakuraBridge.setINIBool("Sakura/UI", key: "PhoneVibrationFallback", value: phoneVibrationFallback) }
    }

    var captureDestination: String = "documents" {
        didSet { UserDefaults.standard.set(captureDestination, forKey: "sakura.capture.destination") }
    }
    var captureScope: String = "full" {
        didSet { UserDefaults.standard.set(captureScope, forKey: "sakura.capture.scope") }
    }
    var topBarSwapSpeedForRecord: Bool = false {
        didSet { UserDefaults.standard.set(topBarSwapSpeedForRecord, forKey: "sakura.topbar.swapSpeedForRecord") }
    }
    
    enum MediaAttachStateMode: String {
        case off
        case start
        case both
    }
    var mediaAttachStateOnScreenshot: Bool = true {
        didSet { UserDefaults.standard.set(mediaAttachStateOnScreenshot, forKey: "sakura.media.attachStateScreenshot") }
    }
    var mediaAttachStateOnRecordingRaw: String = MediaAttachStateMode.start.rawValue {
        didSet { UserDefaults.standard.set(mediaAttachStateOnRecordingRaw, forKey: "sakura.media.attachStateRecording") }
    }
    var mediaAttachStateOnRecording: MediaAttachStateMode {
        get { MediaAttachStateMode(rawValue: mediaAttachStateOnRecordingRaw) ?? .start }
        set { mediaAttachStateOnRecordingRaw = newValue.rawValue }
    }
    var mediaShowAttachedStateBadge: Bool = true {
        didSet { UserDefaults.standard.set(mediaShowAttachedStateBadge, forKey: "sakura.media.showAttachedStateBadge") }
    }
    var mediaScreenshotOnSaveState: Bool = true {
        didSet { UserDefaults.standard.set(mediaScreenshotOnSaveState, forKey: "sakura.media.screenshotOnSaveState") }
    }

    /// one-shot: earlier builds forced ScreenCapture INI false; restores adjacent slot preview renders.
    private static func restoreAdjacentSlotPreviewIfDrainedOnce() {
        let k = "sakura.migrate.adjacentSlotPreview20260503"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: k) else { return }
        defaults.set(true, forKey: k)
        SakuraBridge.setINIBool("Sakura/SaveStates", key: "ScreenCapture", value: true)
    }

    static func localizedSaveStateRecordingOptions() -> [(value: String, label: String)] {
        [
            (MediaAttachStateMode.off.rawValue,   SakuraL10n.tr("general.saveStateRecording.off")),
            (MediaAttachStateMode.start.rawValue, SakuraL10n.tr("general.saveStateRecording.start")),
            (MediaAttachStateMode.both.rawValue,  SakuraL10n.tr("general.saveStateRecording.both")),
        ]
    }

    static let pgxpModeOptions: [(value: String, label: String)] = [
        ("disabled", "Off"),
        ("memory only", "Memory Only"),
        ("memory + CPU", "Memory + CPU"),
    ]

    private static func normalizedPGXPMode(forStored raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "off" || trimmed == "disabled" {
            return "disabled"
        }
        let allowed = Set(pgxpModeOptions.map(\.value))
        return allowed.contains(trimmed) ? trimmed : "disabled"
    }

    var pgxpMode: String {
        didSet {
            let norm = Self.normalizedPGXPMode(forStored: pgxpMode)
            if norm != pgxpMode {
                pgxpMode = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "PGXPMode", value: pgxpMode)
            Self.liveApply()
        }
    }
    var widescreenHack: Bool {
        didSet { SakuraBridge.setINIBool("PSX/Core", key: "WidescreenHack", value: widescreenHack); Self.liveApply() }
    }
    static let ditherModeOptions: [(value: String, label: String)] = [
        ("1x(native)", "Native"),
        ("internal resolution", "Resolution"),
        ("disabled", "Off"),
    ]

    private static func normalizedDitherMode(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "off" { return "disabled" }
        let allowed = Set(ditherModeOptions.map(\.value))
        if allowed.contains(t) { return t }
        return "1x(native)"
    }

    var ditherMode: String {
        didSet {
            let norm = Self.normalizedDitherMode(forStored: ditherMode)
            if norm != ditherMode {
                ditherMode = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "DitherMode", value: ditherMode)
            Self.liveApply()
        }
    }
    static let internalColorDepthOptions: [(value: String, label: String)] = [
        ("dithered 16bpp (native)", "16bpp"),
        ("32bpp", "32bpp"),
    ]

    private static func normalizedInternalColorDepth(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(internalColorDepthOptions.map(\.value))
        if allowed.contains(t) { return t }
        if t == "dithered 16bpp" { return "dithered 16bpp (native)" }
        return "dithered 16bpp (native)"
    }

    var internalColorDepth: String {
        didSet {
            let norm = Self.normalizedInternalColorDepth(forStored: internalColorDepth)
            if norm != internalColorDepth {
                internalColorDepth = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "InternalColorDepth", value: internalColorDepth)
            Self.liveApply()
        }
    }
    var frameDuping: Bool {
        didSet { SakuraBridge.setINIBool("PSX/Core", key: "FrameDuping", value: frameDuping); Self.liveApply() }
    }

    static let ps1DeinterlacerOptions: [(value: String, label: String)] = [
        ("bob", "Bob"),
        ("weave", "Weave"),
    ]

    static func normalizedPs1Deinterlacer(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "weave" { return "weave" }
        return "bob"
    }

    var ps1Deinterlacer: String {
        didSet {
            let norm = Self.normalizedPs1Deinterlacer(forStored: ps1Deinterlacer)
            if norm != ps1Deinterlacer {
                ps1Deinterlacer = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "Deinterlacer", value: ps1Deinterlacer)
            Self.liveApply()
        }
    }

    static let cropOverscanOptions: [(value: String, label: String)] = [
        ("smart", "Smart"),
        ("static", "Horizontal"),
        ("disabled", "Off"),
    ]

    static func normalizedCropOverscan(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "static" || t == "horizontal" { return "static" }
        if t == "disabled" || t == "off" || t == "none" { return "disabled" }
        return "smart"
    }

    var cropOverscan: String {
        didSet {
            let norm = Self.normalizedCropOverscan(forStored: cropOverscan)
            if norm != cropOverscan {
                cropOverscan = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "CropOverscan", value: cropOverscan)
            Self.liveApply()
        }
    }

    static let cpuFreqScaleOptions: [(value: String, label: String)] = [
        ("50%", "50%"),
        ("75%", "75%"),
        ("100%", "100%"),
        ("150%", "150%"),
        ("200%", "200%"),
    ]

    private static func normalizedCpuFreqScale(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = cpuFreqScaleOptions.map(\.value)
        if allowed.contains(t) { return t }
        let digits = String(t.filter(\.isNumber))
        guard let p = Int(digits), !digits.isEmpty else { return "100%" }
        let pairs: [(String, Int)] = allowed.compactMap { s in
            let d = String(s.filter(\.isNumber))
            guard let n = Int(d) else { return nil }
            return (s, n)
        }
        return pairs.min(by: { abs($0.1 - p) < abs($1.1 - p) })?.0 ?? "100%"
    }

    var cpuFreqScale: String {
        didSet {
            let norm = Self.normalizedCpuFreqScale(forStored: cpuFreqScale)
            if norm != cpuFreqScale {
                cpuFreqScale = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "CPUFreqScale", value: cpuFreqScale)
            Self.liveApply()
        }
    }
    static let cdAccessMethodOptions: [(value: String, label: String)] = [
        ("precache", "Precache"),
        ("sync", "Sync"),
        ("async", "Async"),
    ]

    private static func normalizedCdAccessMethod(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(cdAccessMethodOptions.map(\.value))
        if allowed.contains(t) { return t }
        if t == "synchronous" { return "sync" }
        if t == "asynchronous" { return "async" }
        if t == "pre-cache" { return "precache" }
        return "sync"
    }

    var cdAccessMethod: String {
        didSet {
            let norm = Self.normalizedCdAccessMethod(forStored: cdAccessMethod)
            if norm != cdAccessMethod {
                cdAccessMethod = norm
                return
            }
            SakuraBridge.setINIString("PSX/Core", key: "CDAccessMethod", value: cdAccessMethod)
            Self.liveApply()
        }
    }

    static let hostEmulationSpeedOptions: [(value: Float, label: String)] = [
        (0.5, "0.5×"),
        (1.0, "1×"),
        (1.5, "1.5×"),
        (2.0, "2×"),
        (3.0, "3×"),
        (4.0, "4×"),
    ]
    var hostEmulationSpeed: Float {
        didSet {
            let snap = Self.snapHostEmulationSpeed(hostEmulationSpeed)
            if snap != hostEmulationSpeed {
                hostEmulationSpeed = snap
                return
            }
            SakuraBridge.setINIFloat("PSX/Core", key: "host_emulation_speed", value: hostEmulationSpeed)
            if SakuraBridge.isEmulationRunning() {
                SakuraBridge.applyRunningHostEmulationSpeedLive(hostEmulationSpeed)
            } else {
                Self.liveApply()
            }
        }
    }

    var audioLatency: Int = 128 {
        didSet {
            let clamped = max(0, min(512, audioLatency))
            if clamped != audioLatency {
                audioLatency = clamped
                return
            }
            SakuraBridge.setINIInt("PSX/Core", key: "audio_latency_ms", value: Int32(audioLatency))
            Self.liveApply()
        }
    }

    var audioSync: Bool = true {
        didSet {
            SakuraBridge.setINIBool("PSX/Core", key: "audio_sync", value: audioSync)
            Self.liveApply()
        }
    }

    var muteAudioWhenTurbo: Bool = true {
        didSet {
            SakuraBridge.setINIBool("PSX/Core", key: "mute_audio_when_turbo", value: muteAudioWhenTurbo)
            Self.liveApply()
        }
    }

    var audioTimeStretch: Bool = true {
        didSet {
            SakuraBridge.setINIBool("PSX/Core", key: "audio_time_stretch", value: audioTimeStretch)
            Self.liveApply()
        }
    }

    private static func snapHostEmulationSpeed(_ raw: Float) -> Float {
        let presets = hostEmulationSpeedOptions.map(\.value)
        return presets.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private static func readMainThreadMetalPresentFromINI() -> Bool {
        SakuraBridge.getINIBool("EmuCore/GS", key: "split_present", defaultValue: true)
    }

    private static func coerceNeuralModelToken(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            return NeuralUpscaleRegistry.bundledINIValue
        }
        let allowed = Set(NeuralUpscaleRegistry.modelPickerOptions().map(\.iniValue))
        let normalized = NeuralUpscaleRegistry.normalizedNeuralModelINIToken(t)
        if allowed.contains(normalized) {
            return normalized
        }
        if allowed.contains(t) {
            return t
        }
        return NeuralUpscaleRegistry.bundledINIValue
    }

    private static func loadPresentColorAdjustFromINI(into store: SettingsStore) {
        let rawIniSat = SakuraBridge.getINIFloat("EmuCore/GS", key: "display_color_saturation", defaultValue: 1)
        if SakuraBridge.containsINIValue("EmuCore/GS", key: "color_adjust_enabled") {
            store.colorAdjustEnabled = SakuraBridge.getINIBool("EmuCore/GS", key: "color_adjust_enabled", defaultValue: false)
        } else {
            store.colorAdjustEnabled = abs(rawIniSat - 1) > 0.0001
        }
        store.colorAdjustBrightness = PresentationColor.uniformBrightness(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_brightness", defaultValue: PresentationColor.iniBrightness(fromUniform: 0))
        )
        store.colorAdjustContrast = PresentationColor.uniformContrast(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_contrast", defaultValue: PresentationColor.iniContrast(fromUniform: 0))
        )
        store.colorAdjustVibrance = PresentationColor.uniformVibrance(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_vibrance", defaultValue: PresentationColor.iniVibrance(fromUniform: 0))
        )
        store.colorAdjustExposure = PresentationColor.uniformExposure(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_exposure", defaultValue: PresentationColor.iniExposure(fromUniform: 0))
        )
        store.colorAdjustGamma = PresentationColor.uniformGamma(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_gamma", defaultValue: PresentationColor.iniGamma(fromUniform: 0))
        )
        store.colorAdjustColorTemperature = PresentationColor.uniformColorTemperature(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_temperature", defaultValue: PresentationColor.iniColorTemperature(fromUniform: 0))
        )
        store.colorAdjustSharpness = PresentationColor.uniformSharpness(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_sharpness", defaultValue: PresentationColor.iniSharpness(fromUniform: 0))
        )
        store.colorAdjustBloom = PresentationColor.uniformBloomIntensity(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_bloom", defaultValue: PresentationColor.iniBloomIntensity(fromUniform: 0))
        )
        store.colorAdjustBloomRadius = PresentationColor.uniformBloomRadius(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_bloom_radius", defaultValue: PresentationColor.iniBloomRadius(fromUniform: 0))
        )
        store.colorAdjustVignette = PresentationColor.uniformVignetteIntensity(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_vignette", defaultValue: PresentationColor.iniVignetteIntensity(fromUniform: 0))
        )
        store.colorAdjustVignetteRadius = PresentationColor.uniformVignetteRadius(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_vignette_radius", defaultValue: PresentationColor.iniVignetteRadius(fromUniform: 0))
        )
        if PresentationColor.extendedBrightnessAvailable {
            store.colorAdjustHdrEnabled = SakuraBridge.getINIBool("EmuCore/GS", key: "color_adjust_hdr_enabled", defaultValue: false)
        } else {
            store.colorAdjustHdrEnabled = false
        }
        store.colorAdjustHdrExposure = PresentationColor.uniformHdrExposure(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_hdr_exposure", defaultValue: PresentationColor.iniHdrExposure(fromUniform: 0))
        )
        store.colorAdjustHdrSaturation = PresentationColor.uniformHdrSaturation(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_hdr_saturation", defaultValue: 1)
        )
        store.colorAdjustHdrContrast = PresentationColor.uniformHdrContrast(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_hdr_contrast", defaultValue: PresentationColor.iniHdrContrast(fromUniform: 0))
        )
        store.colorAdjustHdrBloom = PresentationColor.uniformHdrBloom(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_hdr_bloom", defaultValue: PresentationColor.iniHdrBloom(fromUniform: 0))
        )
        store.colorAdjustHdrShadowLift = PresentationColor.uniformHdrShadowLift(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_hdr_shadow_lift", defaultValue: PresentationColor.iniHdrShadowLift(fromUniform: 0))
        )
        store.colorAdjustHdrHighlightCompress = PresentationColor.uniformHdrHighlightCompress(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "color_adjust_hdr_highlight_compress", defaultValue: PresentationColor.iniHdrHighlightCompress(fromUniform: 0))
        )
    }

    // MARK: - Init from INI

    private init() {
        // dev @autonomy.md
        SakuraBridge.logINIDiagnostics("SettingsStore.init.enter")
        SakuraBridge.setINIWriteSuppressed(true)
        fastBoot  = SakuraBridge.getINIBool("GameISO", key: "FastBoot", defaultValue: false)
        upscaleMultiplier = Self.normalizeUpscaleFromINI(SakuraBridge.getINIFloat("EmuCore/GS", key: "upscale_multiplier", defaultValue: 1.0))
        textureFiltering = max(0, min(7, Int(SakuraBridge.getINIInt("EmuCore/GS", key: "filter", defaultValue: 2))))
        fxaa = SakuraBridge.getINIBool("EmuCore/GS", key: "fxaa", defaultValue: false)
        smaaQuality = max(0, min(4, Int(SakuraBridge.getINIInt("EmuCore/GS", key: "smaa_quality", defaultValue: 0))))
        smaaLinearSpace = SakuraBridge.getINIBool("EmuCore/GS", key: "smaa_linear", defaultValue: true)
        smaaAdaptiveThreshold = SakuraBridge.getINIBool("EmuCore/GS", key: "smaa_adaptive", defaultValue: true)
        smaaPixelArtMode = SakuraBridge.getINIBool("EmuCore/GS", key: "smaa_pixel_art", defaultValue: true)
        smaaThresholdScale = min(max(SakuraBridge.getINIFloat("EmuCore/GS", key: "smaa_threshold_scale", defaultValue: 1.0), 0.1), 4.0)
        smaaPixelArtTolerance = min(max(SakuraBridge.getINIFloat("EmuCore/GS", key: "smaa_pixel_art_tol", defaultValue: 0.04), 0.001), 0.2)
        displayColorSaturation = PresentationColor.uniformDisplayColorSaturation(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "display_color_saturation", defaultValue: 1)
        )
        metalFXTexture = SakuraBridge.getINIBool("EmuCore/GS", key: "metalfx_texture", defaultValue: false)
        metalFXTemporalDisplay = SakuraBridge.getINIBool("EmuCore/GS", key: "metalfx_temporal_display", defaultValue: false)
        mainThreadMetalPresentEnabled = Self.readMainThreadMetalPresentFromINI()
        videotoolboxFrameFeatures = SakuraBridge.getINIBool("EmuCore/GS", key: "videotoolbox_ios26_frame_features", defaultValue: true)
        metalFXFrameInterpolation = SakuraBridge.getINIBool("EmuCore/GS", key: "metalfx_frame_interpolation", defaultValue: false)
        neuralUpscaleLive = SakuraBridge.getINIBool("EmuCore/GS", key: "neural_upscale_live", defaultValue: false)
        neuralUpscaleTextureArt = SakuraBridge.getINIBool("EmuCore/GS", key: "neural_upscale_texture_art", defaultValue: false)
        let rawNeuralModelInit = SakuraBridge.getINIString(
            "EmuCore/GS",
            key: "neural_upscale_model",
            defaultValue: NeuralUpscaleRegistry.bundledINIValue
        )
        neuralUpscaleModelToken = Self.coerceNeuralModelToken(rawNeuralModelInit)
        casMode = Int(SakuraBridge.getINIInt("EmuCore/GS", key: "CASMode", defaultValue: 0))
        casSharpness = max(0, min(100, Int(SakuraBridge.getINIInt("EmuCore/GS", key: "CASSharpness", defaultValue: 50))))
        aspectRatio = Self.currentAspectRatioIndex()
        nativeScaleMetalDrawable = Int(SakuraBridge.getINIInt("EmuCore/GS", key: "Renderer", defaultValue: 17)) == 14
        padOpacity = SakuraBridge.getINIFloat("Sakura/UI", key: "PadOpacity", defaultValue: 0.6)
        pauseOnMenuEnabled = SakuraBridge.getINIBool("Sakura/UI", key: "PauseOnMenu", defaultValue: true)
        hapticFeedback = SakuraBridge.getINIBool("Sakura/UI", key: "HapticFeedback", defaultValue: true)
        controllerAutoSwitch = SakuraBridge.getINIBool("Controller", key: "AutoSwitch", defaultValue: false)
        controllerRumbleEnabled = SakuraBridge.getINIBool("Sakura/UI", key: "ControllerRumble", defaultValue: true)
        controllerRumbleIntensity = SakuraBridge.getINIFloat("Sakura/UI", key: "ControllerRumbleIntensity", defaultValue: 1.0)
        controllerPortAssignmentsRaw = SakuraBridge.getINIString("Controller", key: "PortAssignments", defaultValue: "{}")
        phoneVibrationFallback = SakuraBridge.getINIBool("Sakura/UI", key: "PhoneVibrationFallback", defaultValue: true)
        let rawPGXPINI = SakuraBridge.getINIString("PSX/Core", key: "PGXPMode", defaultValue: "disabled")
        pgxpMode = Self.normalizedPGXPMode(forStored: rawPGXPINI)
        widescreenHack = SakuraBridge.getINIBool("PSX/Core", key: "WidescreenHack", defaultValue: false)
        ditherMode = Self.normalizedDitherMode(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "DitherMode", defaultValue: "1x(native)")
        )
        internalColorDepth = Self.normalizedInternalColorDepth(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "InternalColorDepth", defaultValue: "dithered 16bpp (native)")
        )
        frameDuping = SakuraBridge.getINIBool("PSX/Core", key: "FrameDuping", defaultValue: true)
        let rawDeinterlacerINI = SakuraBridge.getINIString("PSX/Core", key: "Deinterlacer", defaultValue: "bob")
        ps1Deinterlacer = Self.normalizedPs1Deinterlacer(forStored: rawDeinterlacerINI)
        let rawCropOverscanINI = SakuraBridge.getINIString("PSX/Core", key: "CropOverscan", defaultValue: "smart")
        cropOverscan = Self.normalizedCropOverscan(forStored: rawCropOverscanINI)
        cpuFreqScale = Self.normalizedCpuFreqScale(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "CPUFreqScale", defaultValue: "100%")
        )
        cdAccessMethod = Self.normalizedCdAccessMethod(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "CDAccessMethod", defaultValue: "sync")
        )
        hostEmulationSpeed = Self.snapHostEmulationSpeed(SakuraBridge.getINIFloat("PSX/Core", key: "host_emulation_speed", defaultValue: 1.0))
        audioLatency = Int(SakuraBridge.getINIInt("PSX/Core", key: "audio_latency_ms", defaultValue: 128))
        audioSync = SakuraBridge.getINIBool("PSX/Core", key: "audio_sync", defaultValue: true)
        muteAudioWhenTurbo = SakuraBridge.getINIBool("PSX/Core", key: "mute_audio_when_turbo", defaultValue: true)
        audioTimeStretch = SakuraBridge.getINIBool("PSX/Core", key: "audio_time_stretch", defaultValue: true)
        Self.loadPresentColorAdjustFromINI(into: self)
        Self.loadHudDefaults(into: self)
        SakuraBridge.setINIWriteSuppressed(false)
        Self.restoreAdjacentSlotPreviewIfDrainedOnce()
        if rawNeuralModelInit != neuralUpscaleModelToken {
            SakuraBridge.setINIString("EmuCore/GS", key: "neural_upscale_model", value: neuralUpscaleModelToken)
        }
        if rawPGXPINI != pgxpMode {
            SakuraBridge.setINIString("PSX/Core", key: "PGXPMode", value: pgxpMode)
        }
        if rawDeinterlacerINI != ps1Deinterlacer {
            SakuraBridge.setINIString("PSX/Core", key: "Deinterlacer", value: ps1Deinterlacer)
        }
        if rawCropOverscanINI != cropOverscan {
            SakuraBridge.setINIString("PSX/Core", key: "CropOverscan", value: cropOverscan)
        }
        SakuraBridge.logINIDiagnostics("SettingsStore.init.exit")
    }

    private static func loadHudDefaults(into store: SettingsStore) {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil
                ? fallback : UserDefaults.standard.bool(forKey: key)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            UserDefaults.standard.object(forKey: key) == nil
                ? fallback : UserDefaults.standard.integer(forKey: key)
        }
        store.hudEnabled       = bool("sakura.hud.enabled", true)
        UserDefaults.standard.removeObject(forKey: "sakura.hud.compact")
        store.hudRefreshRate   = int("sakura.hud.refreshRate", 6)
        store.hudShowFPS           = bool("sakura.hud.show.fps", true)
        store.hudShowSpeed         = bool("sakura.hud.show.speed", true)
        store.hudShowAvgLow        = bool("sakura.hud.show.avgLow", false)
        store.hudShowFrameTime     = bool("sakura.hud.show.frameTime", true)
        store.hudShowCPU           = bool("sakura.hud.show.cpu", true)
        store.hudShowRAM           = bool("sakura.hud.show.ram", true)
        store.hudShowGPU           = bool("sakura.hud.show.gpu", true)
        store.hudShowResolution    = bool("sakura.hud.show.resolution", true)
        store.hudShowTemperature   = bool("sakura.hud.show.thermal", true)
        store.hudShowBattery       = bool("sakura.hud.show.battery", true)
        store.hudShowGraphs        = bool("sakura.hud.show.graphs", true)

        store.topBarHideBattery     = bool("sakura.topbar.hideBattery", false)
        store.topBarHideMusic       = bool("sakura.topbar.hideMusic", true)
        store.bottomActionBarHidden = bool("sakura.library.bottomBarHidden", false)
        Self.loadEmuMenuDefaults(into: store)
    }

    private static func loadEmuMenuDefaults(into store: SettingsStore) {
        let d = UserDefaults.standard
        store.emuMenuKeepSubmenusOpen = d.object(forKey: "Sakura/EmulationMenu/keepSubmenusOpen") as? Bool ?? false
        store.emuMenuPreventScreenSleep = d.object(forKey: "Sakura/EmulationMenu/preventScreenSleep") as? Bool ?? true
        store.emuMenuConfirmOnStop = d.object(forKey: "sakura.emuMenu.confirmOnStop") as? Bool ?? true
        if let raw = d.string(forKey: "Sakura/EmulationMenu/autoHideBarOption"),
           let option = AutoHideBarOption(rawValue: raw) {
            store.emuMenuAutoHideBarRaw = raw
        }
    }
    
    func reload() {
        SakuraBridge.logINIDiagnostics("SettingsStore.reload.enter")
        
        let defaults = UserDefaults.standard
        if let s = defaults.object(forKey: "sakura.capture.destination") as? String { captureDestination = s }
        if let s = defaults.object(forKey: "sakura.capture.scope") as? String { captureScope = s }
        if let b = defaults.object(forKey: "sakura.topbar.swapSpeedForRecord") as? Bool { topBarSwapSpeedForRecord = b }
        
        if let b = defaults.object(forKey: "sakura.media.attachStateScreenshot") as? Bool { mediaAttachStateOnScreenshot = b }
        if let s = defaults.object(forKey: "sakura.media.attachStateRecording") as? String { mediaAttachStateOnRecordingRaw = s }
        if let b = defaults.object(forKey: "sakura.media.showAttachedStateBadge") as? Bool { mediaShowAttachedStateBadge = b }
        if let b = defaults.object(forKey: "sakura.media.screenshotOnSaveState") as? Bool { mediaScreenshotOnSaveState = b }

        fastBoot = SakuraBridge.getINIBool("GameISO", key: "FastBoot", defaultValue: false)
        upscaleMultiplier = Self.normalizeUpscaleFromINI(SakuraBridge.getINIFloat("EmuCore/GS", key: "upscale_multiplier", defaultValue: 1.0))
        textureFiltering = max(0, min(7, Int(SakuraBridge.getINIInt("EmuCore/GS", key: "filter", defaultValue: 2))))
        fxaa = SakuraBridge.getINIBool("EmuCore/GS", key: "fxaa", defaultValue: false)
        smaaQuality = max(0, min(4, Int(SakuraBridge.getINIInt("EmuCore/GS", key: "smaa_quality", defaultValue: 0))))
        smaaLinearSpace = SakuraBridge.getINIBool("EmuCore/GS", key: "smaa_linear", defaultValue: true)
        smaaAdaptiveThreshold = SakuraBridge.getINIBool("EmuCore/GS", key: "smaa_adaptive", defaultValue: true)
        smaaPixelArtMode = SakuraBridge.getINIBool("EmuCore/GS", key: "smaa_pixel_art", defaultValue: true)
        smaaThresholdScale = min(max(SakuraBridge.getINIFloat("EmuCore/GS", key: "smaa_threshold_scale", defaultValue: 1.0), 0.1), 4.0)
        smaaPixelArtTolerance = min(max(SakuraBridge.getINIFloat("EmuCore/GS", key: "smaa_pixel_art_tol", defaultValue: 0.04), 0.001), 0.2)
        displayColorSaturation = PresentationColor.uniformDisplayColorSaturation(
            fromIni: SakuraBridge.getINIFloat("EmuCore/GS", key: "display_color_saturation", defaultValue: 1)
        )
        Self.loadPresentColorAdjustFromINI(into: self)
        metalFXTexture = SakuraBridge.getINIBool("EmuCore/GS", key: "metalfx_texture", defaultValue: false)
        metalFXTemporalDisplay = SakuraBridge.getINIBool("EmuCore/GS", key: "metalfx_temporal_display", defaultValue: false)
        mainThreadMetalPresentEnabled = Self.readMainThreadMetalPresentFromINI()
        videotoolboxFrameFeatures = SakuraBridge.getINIBool("EmuCore/GS", key: "videotoolbox_ios26_frame_features", defaultValue: true)
        metalFXFrameInterpolation = SakuraBridge.getINIBool("EmuCore/GS", key: "metalfx_frame_interpolation", defaultValue: false)
        neuralUpscaleLive = SakuraBridge.getINIBool("EmuCore/GS", key: "neural_upscale_live", defaultValue: false)
        neuralUpscaleTextureArt = SakuraBridge.getINIBool("EmuCore/GS", key: "neural_upscale_texture_art", defaultValue: false)
        let rawNeuralModelReload = SakuraBridge.getINIString(
            "EmuCore/GS",
            key: "neural_upscale_model",
            defaultValue: NeuralUpscaleRegistry.bundledINIValue
        )
        neuralUpscaleModelToken = Self.coerceNeuralModelToken(rawNeuralModelReload)
        casMode = Int(SakuraBridge.getINIInt("EmuCore/GS", key: "CASMode", defaultValue: 0))
        casSharpness = max(0, min(100, Int(SakuraBridge.getINIInt("EmuCore/GS", key: "CASSharpness", defaultValue: 50))))
        aspectRatio = Self.currentAspectRatioIndex()
        nativeScaleMetalDrawable = Int(SakuraBridge.getINIInt("EmuCore/GS", key: "Renderer", defaultValue: 17)) == 14
        padOpacity = SakuraBridge.getINIFloat("Sakura/UI", key: "PadOpacity", defaultValue: 0.6)
        pauseOnMenuEnabled = SakuraBridge.getINIBool("Sakura/UI", key: "PauseOnMenu", defaultValue: true)
        hapticFeedback = SakuraBridge.getINIBool("Sakura/UI", key: "HapticFeedback", defaultValue: true)
        controllerAutoSwitch = SakuraBridge.getINIBool("Controller", key: "AutoSwitch", defaultValue: false)
        controllerRumbleEnabled = SakuraBridge.getINIBool("Sakura/UI", key: "ControllerRumble", defaultValue: true)
        controllerRumbleIntensity = SakuraBridge.getINIFloat("Sakura/UI", key: "ControllerRumbleIntensity", defaultValue: 1.0)
        controllerPortAssignmentsRaw = SakuraBridge.getINIString("Controller", key: "PortAssignments", defaultValue: "{}")
        phoneVibrationFallback = SakuraBridge.getINIBool("Sakura/UI", key: "PhoneVibrationFallback", defaultValue: true)
        let rawPGXPINI = SakuraBridge.getINIString("PSX/Core", key: "PGXPMode", defaultValue: "disabled")
        pgxpMode = Self.normalizedPGXPMode(forStored: rawPGXPINI)
        widescreenHack = SakuraBridge.getINIBool("PSX/Core", key: "WidescreenHack", defaultValue: false)
        ditherMode = Self.normalizedDitherMode(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "DitherMode", defaultValue: "1x(native)")
        )
        internalColorDepth = Self.normalizedInternalColorDepth(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "InternalColorDepth", defaultValue: "dithered 16bpp (native)")
        )
        frameDuping = SakuraBridge.getINIBool("PSX/Core", key: "FrameDuping", defaultValue: true)
        let rawDeinterlacerReloadINI = SakuraBridge.getINIString("PSX/Core", key: "Deinterlacer", defaultValue: "bob")
        ps1Deinterlacer = Self.normalizedPs1Deinterlacer(forStored: rawDeinterlacerReloadINI)
        let rawCropOverscanReloadINI = SakuraBridge.getINIString("PSX/Core", key: "CropOverscan", defaultValue: "smart")
        cropOverscan = Self.normalizedCropOverscan(forStored: rawCropOverscanReloadINI)
        cpuFreqScale = Self.normalizedCpuFreqScale(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "CPUFreqScale", defaultValue: "100%")
        )
        cdAccessMethod = Self.normalizedCdAccessMethod(
            forStored: SakuraBridge.getINIString("PSX/Core", key: "CDAccessMethod", defaultValue: "sync")
        )
        hostEmulationSpeed = Self.snapHostEmulationSpeed(SakuraBridge.getINIFloat("PSX/Core", key: "host_emulation_speed", defaultValue: 1.0))
        audioLatency = Int(SakuraBridge.getINIInt("PSX/Core", key: "audio_latency_ms", defaultValue: 128))
        audioSync = SakuraBridge.getINIBool("PSX/Core", key: "audio_sync", defaultValue: true)
        muteAudioWhenTurbo = SakuraBridge.getINIBool("PSX/Core", key: "mute_audio_when_turbo", defaultValue: true)
        audioTimeStretch = SakuraBridge.getINIBool("PSX/Core", key: "audio_time_stretch", defaultValue: true)
        Self.loadHudDefaults(into: self)
        SakuraBridge.setINIWriteSuppressed(false)
        Self.restoreAdjacentSlotPreviewIfDrainedOnce()
        if rawNeuralModelReload != neuralUpscaleModelToken {
            SakuraBridge.setINIString("EmuCore/GS", key: "neural_upscale_model", value: neuralUpscaleModelToken)
        }
        if rawPGXPINI != pgxpMode {
            SakuraBridge.setINIString("PSX/Core", key: "PGXPMode", value: pgxpMode)
        }
        if rawDeinterlacerReloadINI != ps1Deinterlacer {
            SakuraBridge.setINIString("PSX/Core", key: "Deinterlacer", value: ps1Deinterlacer)
        }
        if rawCropOverscanReloadINI != cropOverscan {
            SakuraBridge.setINIString("PSX/Core", key: "CropOverscan", value: cropOverscan)
        }
        SakuraBridge.logINIDiagnostics("SettingsStore.reload.exit")
        SakuraBridge.applyEmulatorSettingsImmediately()
    }

    func resetEmulatorDefaults() {
        fastBoot = false
    }

    func resetGraphicsDefaults() {
        nativeScaleMetalDrawable = false
        upscaleMultiplier = 1.0
        textureFiltering = 2
        fxaa = false
        smaaQuality = 0
        smaaLinearSpace = true
        smaaAdaptiveThreshold = true
        smaaPixelArtMode = true
        smaaThresholdScale = 1.0
        smaaPixelArtTolerance = 0.04
        displayColorSaturation = PresentationColor.uniformSliderDefault
        colorAdjustEnabled = false
        colorAdjustBrightness = PresentationColor.uniformSliderDefault
        colorAdjustContrast = PresentationColor.uniformSliderDefault
        colorAdjustVibrance = PresentationColor.uniformSliderDefault
        colorAdjustExposure = PresentationColor.uniformSliderDefault
        colorAdjustGamma = PresentationColor.uniformSliderDefault
        colorAdjustColorTemperature = PresentationColor.uniformSliderDefault
        colorAdjustSharpness = PresentationColor.uniformSliderDefault
        colorAdjustBloom = PresentationColor.uniformSliderDefault
        colorAdjustBloomRadius = PresentationColor.uniformSliderDefault
        colorAdjustVignette = PresentationColor.uniformSliderDefault
        colorAdjustVignetteRadius = PresentationColor.uniformSliderDefault
        colorAdjustHdrEnabled = false
        colorAdjustHdrExposure = PresentationColor.uniformSliderDefault
        colorAdjustHdrSaturation = PresentationColor.uniformSliderDefault
        colorAdjustHdrContrast = PresentationColor.uniformSliderDefault
        colorAdjustHdrBloom = PresentationColor.uniformSliderDefault
        colorAdjustHdrShadowLift = PresentationColor.uniformSliderDefault
        colorAdjustHdrHighlightCompress = PresentationColor.uniformSliderDefault
        metalFXTexture = false
        metalFXTemporalDisplay = false
        mainThreadMetalPresentEnabled = true
        videotoolboxFrameFeatures = true
        metalFXFrameInterpolation = false
        neuralUpscaleLive = false
        neuralUpscaleTextureArt = false
        neuralUpscaleModelToken = NeuralUpscaleRegistry.bundledINIValue
        casMode = 0
        casSharpness = 50
        aspectRatio = 2
        pgxpMode = "disabled"
        widescreenHack = false
        ditherMode = "1x(native)"
        internalColorDepth = "dithered 16bpp (native)"
        frameDuping = true
        ps1Deinterlacer = "bob"
        cropOverscan = "smart"
        cpuFreqScale = "100%"
        hostEmulationSpeed = 1.0
        cdAccessMethod = "sync"
    }
}

extension SettingsStore {
    static func localizedTextureFilteringOptions() -> [(value: Int, label: String)] {
        textureFilteringOptions.map { ($0.value, SakuraL10n.tr(textureFilteringKey(for: $0.value))) }
    }

    static func localizedSmaaQualityOptions() -> [(value: Int, label: String)] {
        [
            (0, SakuraL10n.tr("graphics.smaa.quality.off")),
            (1, SakuraL10n.tr("graphics.smaa.quality.low")),
            (2, SakuraL10n.tr("graphics.smaa.quality.medium")),
            (3, SakuraL10n.tr("graphics.smaa.quality.high")),
            (4, SakuraL10n.tr("graphics.smaa.quality.ultra")),
        ]
    }

    private static func textureFilteringKey(for v: Int) -> String {
        switch v {
        case 0: return "settings.graphics.texture.nearest"
        case 1: return "settings.graphics.texture.bilinear"
        case 2: return "settings.graphics.texture.threePoint"
        case 3: return "settings.graphics.texture.sabr"
        case 4: return "settings.graphics.texture.xbr"
        case 5: return "settings.graphics.texture.xbrz"
        case 6: return "settings.graphics.texture.fsr1"
        case 7: return "settings.graphics.texture.anime4k"
        default: return "settings.graphics.texture.nearest"
        }
    }

    static func localizedUpscaleMultiplierOptions() -> [(value: Float, label: String)] {
        upscaleMultiplierOptions.map { ($0.value, SakuraL10n.tr(upscaleKey(forMultiplier: $0.value))) }
    }

    private static func upscaleKey(forMultiplier v: Float) -> String {
        switch v {
        case 1: return "settings.graphics.resolution.1x"
        case 1.25: return "settings.graphics.resolution.1_25x"
        case 1.5: return "settings.graphics.resolution.1_5x"
        case 1.75: return "settings.graphics.resolution.1_75x"
        case 2: return "settings.graphics.resolution.2x"
        case 4: return "settings.graphics.resolution.4x"
        case 8: return "settings.graphics.resolution.8x"
        case 16: return "settings.graphics.resolution.16x"
        default: return "settings.graphics.resolution.1x"
        }
    }

    static func localizedPgxpModeOptions() -> [(value: String, label: String)] {
        pgxpModeOptions.map { ($0.value, SakuraL10n.tr(pgxpKey(forStored: $0.value))) }
    }

    private static func pgxpKey(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty || t == "off" || t == "disabled" { return "settings.graphics.pgxp.off" }
        if t == "memory only" { return "settings.graphics.pgxp.memoryOnly" }
        return "settings.graphics.pgxp.memoryCpu"
    }

    static func localizedDitherModeOptions() -> [(value: String, label: String)] {
        ditherModeOptions.map { ($0.value, SakuraL10n.tr(ditherKey(forStored: $0.value))) }
    }

    private static func ditherKey(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "off" || t == "disabled" { return "common.off" }
        if t == "1x(native)" { return "settings.graphics.dither.native" }
        return "settings.graphics.dither.resolution"
    }

    static func localizedInternalColorDepthOptions() -> [(value: String, label: String)] {
        internalColorDepthOptions.map { ($0.value, SakuraL10n.tr(internalDepthKey(forStored: $0.value))) }
    }

    private static func internalDepthKey(forStored raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("16") || t.contains("dithered") { return "settings.graphics.colorDepth.16" }
        return "settings.graphics.colorDepth.32"
    }

    static func localizedPs1DeinterlacerOptions() -> [(value: String, label: String)] {
        ps1DeinterlacerOptions.map { ($0.value, SakuraL10n.tr(ps1DeinterlaceKey(for: $0.value))) }
    }

    private static func ps1DeinterlaceKey(for value: String) -> String {
        switch normalizedPs1Deinterlacer(forStored: value).lowercased() {
        case "weave": return "settings.graphics.ps1Deinterlace.weave"
        default: return "settings.graphics.ps1Deinterlace.bob"
        }
    }

    static func localizedCropOverscanOptions() -> [(value: String, label: String)] {
        cropOverscanOptions.map { ($0.value, SakuraL10n.tr(cropOverscanKey(for: $0.value))) }
    }

    private static func cropOverscanKey(for value: String) -> String {
        switch normalizedCropOverscan(forStored: value) {
        case "static": return "settings.graphics.cropOverscan.horizontal"
        case "disabled": return "settings.graphics.cropOverscan.off"
        default: return "settings.graphics.cropOverscan.smart"
        }
    }

    static func localizedHostEmulationSpeedOptions() -> [(value: Float, label: String)] {
        hostEmulationSpeedOptions.map { ($0.value, SakuraL10n.tr(hostEmuSpeedKey(for: $0.value))) }
    }

    private static func hostEmuSpeedKey(for v: Float) -> String {
        if v == 0.5 { return "settings.performance.speed.0_5x" }
        if v == 1.0 { return "settings.performance.speed.1x" }
        if v == 1.5 { return "settings.performance.speed.1_5x" }
        if v == 2.0 { return "settings.performance.speed.2x" }
        if v == 3.0 { return "settings.performance.speed.3x" }
        if v == 4.0 { return "settings.performance.speed.4x" }
        return "settings.performance.speed.1x"
    }

    static func localizedCpuFreqScaleOptions() -> [(value: String, label: String)] {
        cpuFreqScaleOptions.map { ($0.value, SakuraL10n.tr(cpuFreqKey(for: $0.value))) }
    }

    private static func cpuFreqKey(for raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t {
        case "50%": return "settings.performance.cpu.50"
        case "75%": return "settings.performance.cpu.75"
        case "100%": return "settings.performance.cpu.100"
        case "150%": return "settings.performance.cpu.150"
        case "200%": return "settings.performance.cpu.200"
        default: return "settings.performance.cpu.100"
        }
    }

    static func localizedCdAccessMethodOptions() -> [(value: String, label: String)] {
        cdAccessMethodOptions.map { ($0.value, SakuraL10n.tr(cdAccessKey(forStored: $0.value))) }
    }

    private static func cdAccessKey(forStored raw: String) -> String {
        switch normalizedCdAccessMethod(forStored: raw).lowercased() {
        case "precache": return "settings.performance.cd.precache"
        case "sync": return "settings.performance.cd.sync"
        case "async": return "settings.performance.cd.async"
        default: return "settings.performance.cd.sync"
        }
    }

    static func normalizedCaptureDestination(forStored raw: String?) -> String {
        let t = (raw ?? "documents").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "photos": return "photos"
        case "both": return "both"
        default: return "documents"
        }
    }

    static func normalizedCaptureScope(forStored raw: String?) -> String {
        let t = (raw ?? "full").trimmingCharacters(in: .whitespacesAndNewlines)
        switch t {
        case "hideTouch": return "hideTouch"
        case "minimalChrome": return "minimalChrome"
        case "gameOnly": return "gameOnly"
        default: return "full"
        }
    }

    static func localizedCaptureDestinationOptions() -> [(value: String, label: String)] {
        [
            ("documents", SakuraL10n.tr("general.capture.dest.documents")),
            ("photos", SakuraL10n.tr("general.capture.dest.photos")),
            ("both", SakuraL10n.tr("general.capture.dest.both")),
        ]
    }

    static func localizedCaptureScopeOptions() -> [(value: String, label: String)] {
        [
            ("full", SakuraL10n.tr("general.capture.hide.full")),
            ("hideTouch", SakuraL10n.tr("general.capture.hide.touch")),
            ("minimalChrome", SakuraL10n.tr("general.capture.hide.chrome")),
            ("gameOnly", SakuraL10n.tr("general.capture.hide.gameOnly")),
        ]
    }

    var effectiveCaptureDestination: String {
        Self.normalizedCaptureDestination(forStored: captureDestination)
    }

    var effectiveCaptureScope: String {
        Self.normalizedCaptureScope(forStored: captureScope)
    }

    var recordingHidesVirtualPadWhileCapturing: Bool {
        effectiveCaptureScope != "full"
    }

    var recordingHidesTopBarChromeWhileCapturing: Bool {
        switch effectiveCaptureScope {
        case "minimalChrome", "gameOnly": return true
        default: return false
        }
    }

    var recordingHidesOsdWhileCapturing: Bool {
        effectiveCaptureScope == "gameOnly"
    }
}
