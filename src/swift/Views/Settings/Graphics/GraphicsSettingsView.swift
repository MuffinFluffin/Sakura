// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct GraphicsSettingsView: View {
    @State private var focus = TileFocus.shared
    @Bindable private var settings = SettingsStore.shared

    private var navigationSections: [[String]] {
        var colorIds = ["graphics.colorAdjust"]
        if settings.colorAdjustEnabled {
            if PresentationColor.extendedBrightnessAvailable {
                colorIds.append("graphics.hdrPresentation")
                if settings.colorAdjustHdrEnabled {
                    colorIds.append(contentsOf: [
                        "graphics.hdrSaturation",
                        "graphics.hdrContrast",
                        "graphics.hdrBloom",
                        "graphics.hdrShadowLift",
                        "graphics.hdrHighlightCompress",
                    ])
                }
            }
            colorIds.append(contentsOf: [
                "graphics.colorSaturation",
                "graphics.colorBrightness",
                "graphics.colorContrast",
                "graphics.colorVibrance",
                "graphics.colorExposure",
                "graphics.colorGamma",
                "graphics.colorTemperature",
                "graphics.colorSharpness",
                "graphics.colorBloom",
                "graphics.colorBloomRadius",
                "graphics.colorVignette",
                "graphics.colorVignetteRadius",
            ])
        }
        colorIds.append(contentsOf: ["graphics.dither", "graphics.colorDepth"])
        var displayRow = ["resolution", "nativeDrawable", "aspect", "cropOverscan", "textureFilter", "fxaa", "smaaQuality"]
        if settings.smaaQuality > 0 {
            displayRow.append(contentsOf: ["smaaPixelArt", "smaaAdaptive", "smaaLinear", "smaaThreshold"])
        }
        displayRow.append("cas")
        if settings.casMode != 0 { displayRow.append("casSharpness") }
        displayRow.append(contentsOf: ["frameDuping", "ps1Deinterlacer", "metalFXFrameInterp"])
        let displayPrefixed = displayRow.map { "graphics.\($0)" }
        let enhancementIds = ["graphics.metalFXSpatialScaler", "graphics.metalFXTemporalDisplay", "graphics.neuralFrameCycle"]
        return [
            displayPrefixed,
            enhancementIds,
            ["graphics.mainThreadMetalPresent", "graphics.videotoolbox"],
            ["graphics.pgxp", "graphics.widescreen"],
            colorIds,
            ["graphics.reset"],
        ]
    }

    var body: some View {
        SettingsScroll {
            GraphicsSettingsContent()
        }
        .onAppear {
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.colorAdjustEnabled) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.colorAdjustHdrEnabled) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.casMode) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.smaaQuality) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.neuralUpscaleModelToken) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.neuralUpscaleLive) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
    }
}

/// Same controls used by the Settings tab AND the in-game emu menu.
/// Place inside any container; do NOT add another ScrollView around this.
struct GraphicsSettingsContent: View {
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            displaySection
            enhancementsSection
            videoMetalSection
            geometrySection
            colorSection

            DestructiveTile(
                id: "graphics.reset",
                icon: "arrow.counterclockwise.circle.fill",
                title: SakuraL10n.tr("graphics.tile.reset")
            ) {
                resetGraphicsDefaults()
            }
        }
    }

    private var enhancementsSection: some View {
        SettingSection(
            title: SakuraL10n.tr("graphics.section.enhancements")
        ) {
            TileGrid {
                ToggleTile(
                    id: "graphics.metalFXSpatialScaler",
                    icon: "checkerboard.rectangle",
                    title: SakuraL10n.tr("graphics.tile.metalFXTexture"),
                    isOn: $settings.metalFXTexture
                )
                ToggleTile(
                    id: "graphics.metalFXTemporalDisplay",
                    icon: "film.stack",
                    title: SakuraL10n.tr("graphics.tile.metalFXTemporalDisplay"),
                    isOn: $settings.metalFXTemporalDisplay
                )
                CycleTile(
                    id: "graphics.neuralFrameCycle",
                    icon: "wand.and.stars",
                    title: SakuraL10n.tr("graphics.tile.neuralUpscale"),
                    options: NeuralUpscaleRegistry.frameUpscaleCycleOptions(),
                    selection: neuralUpscaleFramePickerBinding
                )
            }
        }
    }

    private var neuralUpscaleFramePickerBinding: Binding<String> {
        Binding(
            get: {
                settings.neuralUpscaleLive ? settings.neuralUpscaleModelToken : NeuralUpscaleRegistry.frameUpscaleOffToken
            },
            set: { newVal in
                if newVal == NeuralUpscaleRegistry.frameUpscaleOffToken {
                    settings.neuralUpscaleLive = false
                } else {
                    settings.neuralUpscaleModelToken = newVal
                    settings.neuralUpscaleLive = true
                }
            }
        )
    }

    // MARK: Display

    private var displaySection: some View {
        SettingSection(
            title: SakuraL10n.tr("graphics.section.display")
        ) {
            TileGrid {
                CycleTile(
                    id: "graphics.resolution",
                    icon: "arrow.up.right.and.arrow.down.left.rectangle",
                    title: SakuraL10n.tr("graphics.tile.internalResolution"),
                    options: SettingsStore.localizedUpscaleMultiplierOptions(),
                    selection: $settings.upscaleMultiplier
                )
                ToggleTile(
                    id: "graphics.nativeDrawable",
                    icon: "arrow.up.left.and.arrow.down.right",
                    title: SakuraL10n.tr("graphics.tile.nativeMetalDrawable"),
                    isOn: $settings.nativeScaleMetalDrawable
                )
                CycleTile(
                    id: "graphics.aspect",
                    icon: "aspectratio",
                    title: SakuraL10n.tr("graphics.tile.aspectRatio"),
                    options: [
                        (2, SakuraL10n.tr("graphics.aspect.fit")),
                        (3, SakuraL10n.tr("graphics.aspect.fill")),
                    ],
                    selection: $settings.aspectRatio
                )
                CycleTile(
                    id: "graphics.cropOverscan",
                    icon: "rectangle.compress.vertical",
                    title: SakuraL10n.tr("graphics.tile.cropOverscan"),
                    options: SettingsStore.localizedCropOverscanOptions(),
                    selection: $settings.cropOverscan
                )
                CycleTile(
                    id: "graphics.textureFilter",
                    icon: "camera.filters",
                    title: SakuraL10n.tr("graphics.tile.textureFiltering"),
                    options: SettingsStore.localizedTextureFilteringOptions(),
                    selection: $settings.textureFiltering
                )
                ToggleTile(
                    id: "graphics.fxaa",
                    icon: "sparkles",
                    title: SakuraL10n.tr("graphics.tile.fxaa"),
                    isOn: $settings.fxaa
                )
                CycleTile(
                    id: "graphics.smaaQuality",
                    icon: "wand.and.stars",
                    title: SakuraL10n.tr("graphics.tile.smaa"),
                    options: SettingsStore.localizedSmaaQualityOptions(),
                    selection: $settings.smaaQuality
                )
                if settings.smaaQuality > 0 {
                    ToggleTile(
                        id: "graphics.smaaPixelArt",
                        icon: "square.grid.2x2",
                        title: SakuraL10n.tr("graphics.tile.smaa.pixelArt"),
                        isOn: $settings.smaaPixelArtMode
                    )
                    ToggleTile(
                        id: "graphics.smaaAdaptive",
                        icon: "slider.horizontal.below.square.filled.and.square",
                        title: SakuraL10n.tr("graphics.tile.smaa.adaptive"),
                        isOn: $settings.smaaAdaptiveThreshold
                    )
                    ToggleTile(
                        id: "graphics.smaaLinear",
                        icon: "function",
                        title: SakuraL10n.tr("graphics.tile.smaa.linear"),
                        isOn: $settings.smaaLinearSpace
                    )
                    SliderTile(
                        id: "graphics.smaaThreshold",
                        icon: "dial.medium",
                        title: SakuraL10n.tr("graphics.tile.smaa.threshold"),
                        value: Binding(
                            get: { Double(settings.smaaThresholdScale) },
                            set: { settings.smaaThresholdScale = Float($0) }
                        ),
                        range: 0.3...3.0,
                        step: 0.05,
                        format: { String(format: "%.2f", $0) }
                    )
                }
                ToggleTile(
                    id: "graphics.cas",
                    icon: "dial.high",
                    title: SakuraL10n.tr("graphics.tile.cas"),
                    isOn: Binding(
                        get: { settings.casMode != 0 },
                        set: { settings.casMode = $0 ? 1 : 0 }
                    )
                )
                if settings.casMode != 0 {
                    SliderTile(
                        id: "graphics.casSharpness",
                        icon: "triangle.fill",
                        title: SakuraL10n.tr("graphics.tile.casSharpness"),
                        value: Binding(
                            get: { Double(settings.casSharpness) },
                            set: { settings.casSharpness = Int($0.rounded()) }
                        ),
                        range: 0...100,
                        step: 1,
                        format: { "\(Int($0.rounded()))" }
                    )
                }
                ToggleTile(
                    id: "graphics.frameDuping",
                    icon: "rectangle.on.rectangle",
                    title: SakuraL10n.tr("graphics.tile.frameDuping"),
                    isOn: $settings.frameDuping
                )
                CycleTile(
                    id: "graphics.ps1Deinterlacer",
                    icon: "line.3.horizontal",
                    title: SakuraL10n.tr("graphics.tile.ps1Deinterlacer"),
                    options: SettingsStore.localizedPs1DeinterlacerOptions(),
                    selection: $settings.ps1Deinterlacer
                )
                ToggleTile(
                    id: "graphics.metalFXFrameInterp",
                    icon: "waveform.path.ecg.rectangle",
                    title: SakuraL10n.tr("graphics.tile.metalFXFrameInterpolation"),
                    isOn: $settings.metalFXFrameInterpolation
                )
            }
        }
    }

    private var videoMetalSection: some View {
        SettingSection(
            title: SakuraL10n.tr("graphics.section.videoMetal")
        ) {
            TileGrid {
                ToggleTile(
                    id: "graphics.mainThreadMetalPresent",
                    icon: "cpu.fill",
                    title: SakuraL10n.tr("general.tile.mainThreadPresent"),
                    isOn: $settings.mainThreadMetalPresentEnabled
                )
                ToggleTile(
                    id: "graphics.videotoolbox",
                    icon: "film",
                    title: SakuraL10n.tr("graphics.tile.videotoolboxShort"),
                    isOn: $settings.videotoolboxFrameFeatures
                )
            }
        }
    }

    // MARK: Geometry (PGXP)

    private var geometrySection: some View {
        SettingSection(
            title: SakuraL10n.tr("graphics.section.geometry")
        ) {
            TileGrid {
                CycleTile(
                    id: "graphics.pgxp",
                    icon: "scribble.variable",
                    title: SakuraL10n.tr("graphics.tile.pgxp"),
                    options: SettingsStore.localizedPgxpModeOptions(),
                    selection: $settings.pgxpMode
                )
                ToggleTile(
                    id: "graphics.widescreen",
                    icon: "rectangle.expand.diagonal",
                    title: SakuraL10n.tr("graphics.tile.widescreenHack"),
                    isOn: $settings.widescreenHack
                )
            }
        }
    }

    // MARK: Color

    private var colorSection: some View {
        SettingSection(
            title: SakuraL10n.tr("graphics.section.color")
        ) {
            TileGrid(minTileWidth: 280) {
                ToggleTile(
                    id: "graphics.colorAdjust",
                    icon: "paintpalette.fill",
                    title: SakuraL10n.tr("graphics.tile.colorAdjust"),
                    isOn: $settings.colorAdjustEnabled
                )
                if settings.colorAdjustEnabled {
                    if PresentationColor.extendedBrightnessAvailable {
                        ToggleTile(
                            id: "graphics.hdrPresentation",
                            icon: "sun.max.circle.fill",
                            title: SakuraL10n.tr("graphics.tile.hdrEnabled"),
                            isOn: $settings.colorAdjustHdrEnabled
                        )
                        if settings.colorAdjustHdrEnabled {
                            SliderTile(
                                id: "graphics.hdrSaturation",
                                icon: "drop.circle.fill",
                                title: SakuraL10n.tr("graphics.tile.hdrSaturation"),
                                value: Binding(
                                    get: { Double(settings.colorAdjustHdrSaturation) },
                                    set: { settings.colorAdjustHdrSaturation = Float($0) }
                                ),
                                range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                                step: PresentationColor.uniformSliderStep,
                                format: { String(format: "%.2f", $0) }
                            )
                            SliderTile(
                                id: "graphics.hdrContrast",
                                icon: "circle.lefthalf.filled.righthalf.striped.horizontal",
                                title: SakuraL10n.tr("graphics.tile.hdrContrast"),
                                value: Binding(
                                    get: { Double(settings.colorAdjustHdrContrast) },
                                    set: { settings.colorAdjustHdrContrast = Float($0) }
                                ),
                                range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                                step: PresentationColor.uniformSliderStep,
                                format: { String(format: "%.2f", $0) }
                            )
                            SliderTile(
                                id: "graphics.hdrBloom",
                                icon: "sun.haze.fill",
                                title: SakuraL10n.tr("graphics.tile.hdrBloom"),
                                value: Binding(
                                    get: { Double(settings.colorAdjustHdrBloom) },
                                    set: { settings.colorAdjustHdrBloom = Float($0) }
                                ),
                                range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                                step: PresentationColor.uniformSliderStep,
                                format: { String(format: "%.2f", $0) }
                            )
                            SliderTile(
                                id: "graphics.hdrShadowLift",
                                icon: "moon.stars.fill",
                                title: SakuraL10n.tr("graphics.tile.hdrShadowLift"),
                                value: Binding(
                                    get: { Double(settings.colorAdjustHdrShadowLift) },
                                    set: { settings.colorAdjustHdrShadowLift = Float($0) }
                                ),
                                range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                                step: PresentationColor.uniformSliderStep,
                                format: { String(format: "%.2f", $0) }
                            )
                            SliderTile(
                                id: "graphics.hdrHighlightCompress",
                                icon: "sun.dust.fill",
                                title: SakuraL10n.tr("graphics.tile.hdrHighlightRollOff"),
                                value: Binding(
                                    get: { Double(settings.colorAdjustHdrHighlightCompress) },
                                    set: { settings.colorAdjustHdrHighlightCompress = Float($0) }
                                ),
                                range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                                step: PresentationColor.uniformSliderStep,
                                format: { String(format: "%.2f", $0) }
                            )
                        }
                    }
                    SliderTile(
                        id: "graphics.colorSaturation",
                        icon: "drop.circle.fill",
                        title: SakuraL10n.tr("graphics.tile.presentSaturation"),
                        value: Binding(
                            get: { Double(settings.displayColorSaturation) },
                            set: { settings.displayColorSaturation = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorBrightness",
                        icon: "sun.min",
                        title: SakuraL10n.tr("graphics.tile.presentBrightness"),
                        value: Binding(
                            get: { Double(settings.colorAdjustBrightness) },
                            set: { settings.colorAdjustBrightness = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorContrast",
                        icon: "circle.lefthalf.filled.righthalf.striped.horizontal",
                        title: SakuraL10n.tr("graphics.tile.presentContrast"),
                        value: Binding(
                            get: { Double(settings.colorAdjustContrast) },
                            set: { settings.colorAdjustContrast = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorVibrance",
                        icon: "sparkles.square.filled.on.square",
                        title: SakuraL10n.tr("graphics.tile.presentVibrance"),
                        value: Binding(
                            get: { Double(settings.colorAdjustVibrance) },
                            set: { settings.colorAdjustVibrance = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorExposure",
                        icon: "camera.aperture",
                        title: SakuraL10n.tr("graphics.tile.presentExposure"),
                        value: Binding(
                            get: { Double(settings.colorAdjustExposure) },
                            set: { settings.colorAdjustExposure = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorGamma",
                        icon: "chart.bar.doc.horizontal",
                        title: SakuraL10n.tr("graphics.tile.presentGamma"),
                        value: Binding(
                            get: { Double(settings.colorAdjustGamma) },
                            set: { settings.colorAdjustGamma = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorTemperature",
                        icon: "thermometer.medium",
                        title: SakuraL10n.tr("graphics.tile.presentColorTemp"),
                        value: Binding(
                            get: { Double(settings.colorAdjustColorTemperature) },
                            set: { settings.colorAdjustColorTemperature = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorSharpness",
                        icon: "triangle.fill",
                        title: SakuraL10n.tr("graphics.tile.presentSharpness"),
                        value: Binding(
                            get: { Double(settings.colorAdjustSharpness) },
                            set: { settings.colorAdjustSharpness = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorBloom",
                        icon: "sun.haze.fill",
                        title: SakuraL10n.tr("graphics.tile.presentBloom"),
                        value: Binding(
                            get: { Double(settings.colorAdjustBloom) },
                            set: { settings.colorAdjustBloom = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorBloomRadius",
                        icon: "circle.dotted.circle",
                        title: SakuraL10n.tr("graphics.tile.presentBloomRadius"),
                        value: Binding(
                            get: { Double(settings.colorAdjustBloomRadius) },
                            set: { settings.colorAdjustBloomRadius = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorVignette",
                        icon: "vignette",
                        title: SakuraL10n.tr("graphics.tile.presentVignette"),
                        value: Binding(
                            get: { Double(settings.colorAdjustVignette) },
                            set: { settings.colorAdjustVignette = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                    SliderTile(
                        id: "graphics.colorVignetteRadius",
                        icon: "circle.circle.right.half.pattern.checkered",
                        title: SakuraL10n.tr("graphics.tile.presentVignetteRadius"),
                        value: Binding(
                            get: { Double(settings.colorAdjustVignetteRadius) },
                            set: { settings.colorAdjustVignetteRadius = Float($0) }
                        ),
                        range: Double(PresentationColor.uniformSliderMin)...Double(PresentationColor.uniformSliderMax),
                        step: PresentationColor.uniformSliderStep,
                        format: { String(format: "%.2f", $0) }
                    )
                }
                CycleTile(
                    id: "graphics.dither",
                    icon: "circle.grid.3x3",
                    title: SakuraL10n.tr("graphics.tile.dithering"),
                    options: SettingsStore.localizedDitherModeOptions(),
                    selection: $settings.ditherMode
                )
                CycleTile(
                    id: "graphics.colorDepth",
                    icon: "paintpalette",
                    title: SakuraL10n.tr("graphics.tile.internalColorDepth"),
                    options: SettingsStore.localizedInternalColorDepthOptions(),
                    selection: $settings.internalColorDepth
                )
            }
        }
    }

    // MARK: Reset

    private func resetGraphicsDefaults() {
        settings.resetGraphicsDefaults()
    }
}
