// SPDX-License-Identifier: GPL-3.0+

import PhotosUI
import SwiftUI

struct UISettingsView: View {
    @Bindable private var theme = ThemeManager.shared
    @Bindable private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var focus = TileFocus.shared
    @State private var showResetConfirm = false
    @State private var showBackdropImageSourceDialog = false
    @State private var showBackdropVideoSourceDialog = false
    @State private var showBackdropImageImporter = false
    @State private var showBackdropVideoImporter = false
    @State private var showBackdropImageFileImporter = false
    @State private var showBackdropVideoFileImporter = false
    @State private var backdropImageSelection: PhotosPickerItem?
    @State private var backdropVideoSelection: PhotosPickerItem?

    @State private var inGameMenuShortcutLearnStep: Int?

    // MARK: - Controller focus order

    private var navigationSections: [[String]] {
        var background = ["theme.backdrop", "theme.bgTintEnabled", "theme.bgTintStrength"]
        if theme.bgTintEnabled {
            background.append("theme.bgTint")
            background.append("theme.bgTint2")
        }
        background.append(contentsOf: [
            "theme.bgMediaImage", "theme.bgMediaVideo",
            "theme.bgMediaOpacity",
        ])

        return [
            [
                "theme.reduceMotion", "theme.increaseContrast",
                "theme.differentiateWithoutColor", "theme.reduceTransparency",
                "theme.largerTouchTargets", "theme.highContrastOutlines",
                "theme.hapticIntensity", "theme.holdToPress",
            ],
            [
                "theme.accent", "theme.colorScheme", "theme.boxyCorners",
                "theme.glassAccent", "theme.menuTransparency",
            ],
            [
                "theme.neuralTextureArt",
            ],
            background,
            [
                "theme.libraryFontFamily", "theme.libraryFontWeight", "theme.libraryTextScale",
                "theme.libraryTextColor", "theme.libraryCaptionColor"
            ],
            [
                "theme.settingsFontFamily", "theme.settingsFontWeight", "theme.settingsTextScale",
                "theme.settingsTextColor", "theme.settingsCaptionColor"
            ],
            [
                "theme.inGameMenuLite", "theme.inGameMenuDim", "theme.inGameMenuCorner",
                "theme.inGameMenuStrokeOp", "theme.inGameMenuStrokeW",
                "theme.inGameMenuShadow", "theme.inGameTopBarOp",
                "theme.inGameMenuHeader", "theme.inGameMenuBubble", "theme.inGameMenuBubbleFill",
                "theme.inGameMenuIcon", "theme.inGameMenuOuterStroke",
                "theme.inGameMenuText", "theme.inGameMenuCaption", "theme.inGameMenuAccent",
            ],
            [
                "ui.topbar.battery", "ui.topbar.music", "ui.bottombar.hidden",
                "ui.confirmStop",
                "theme.topBarFontFamily", "theme.topBarFontWeight", "theme.topBarTextScale",
                "theme.topBarText", "theme.topBarCaption", "theme.topBarAccent",
            ],
            [
                "theme.notificationFontFamily", "theme.notificationFontWeight", "theme.notificationTextScale",
                "theme.notifTint", "theme.ctrlNotifTint"
            ],
            ["theme.gridSize", "theme.gridSpacing"],
            [
                "theme.hudColor", "theme.hudLabelColor", "theme.hudValueColor",
                "theme.hudGraphColor", "theme.hudTileColor", "theme.hudStrokeColor",
                "theme.hudOpacity", "theme.hudScale", "theme.hudCornerRadius",
                "theme.hudFontFamily", "theme.hudGraphLineWidth",
            ],
            ["music.bgmVolume", "music.playpause", "music.next", "music.loop", "music.import"],
            ["theme.sfxEnabled", "theme.sfxVolume"],
            ["theme.reset"],
        ]
    }

    private func typographyFontOptions() -> [(String, String)] {
        [
            ("system", SakuraL10n.tr("typography.font.system")),
            ("rounded", SakuraL10n.tr("typography.font.rounded")),
            ("serif", SakuraL10n.tr("typography.font.serif")),
            ("mono", SakuraL10n.tr("typography.font.mono")),
        ]
    }

    private func typographyWeightOptions() -> [(String, String)] {
        [
            ("regular", SakuraL10n.tr("typography.weight.regular")),
            ("medium", SakuraL10n.tr("typography.weight.medium")),
            ("semibold", SakuraL10n.tr("typography.weight.semibold")),
            ("bold", SakuraL10n.tr("typography.weight.bold")),
        ]
    }

    private func hudFontCycleOptions() -> [(String, String)] {
        [
            ("mono", SakuraL10n.tr("theme.hud.font.mono")),
            ("rounded", SakuraL10n.tr("theme.hud.font.rounded")),
            ("system", SakuraL10n.tr("theme.hud.font.system")),
        ]
    }

    private func hapticIntensityCycleOptions() -> [(String, String)] {
        [
            ("off", SakuraL10n.tr("common.off")),
            ("light", SakuraL10n.tr("ui.theme.haptic.light")),
            ("medium", SakuraL10n.tr("ui.theme.haptic.medium")),
            ("strong", SakuraL10n.tr("ui.theme.haptic.strong")),
        ]
    }

    private func colorSchemeCycleOptions() -> [(String, String)] {
        [
            ("auto", SakuraL10n.tr("theme.colorScheme.auto")),
            ("light", SakuraL10n.tr("theme.colorScheme.light")),
            ("dark", SakuraL10n.tr("theme.colorScheme.dark")),
        ]
    }

    private func backdropCycleOptions() -> [(String, String)] {
        [
            ("sakura", SakuraL10n.tr("theme.backdrop.sakura")),
            ("onyx", SakuraL10n.tr("theme.backdrop.onyx")),
            ("whiteout", SakuraL10n.tr("theme.backdrop.whiteout")),
        ]
    }

    private func gridSizeCycleOptions() -> [(String, String)] {
        [
            ("small", SakuraL10n.tr("theme.grid.small")),
            ("default", SakuraL10n.tr("theme.grid.defaultSize")),
            ("large", SakuraL10n.tr("theme.grid.large")),
            ("xl", SakuraL10n.tr("theme.grid.extraLarge")),
        ]
    }

    var body: some View {
        SettingsScroll {
            topBarSection
            accessibilitySection
            appearanceSection
            upscaleArtSection
            backgroundSection
            librarySection
            settingsSection
            hudSection
            inGameMenuChromeSection
            notificationsSection
            MusicSection()
            sfxSection
            resetSection
        }
        .onAppear {
            focus.setPage(sections: navigationSections, columnHint: 3)
            MusicPlayer.shared.refreshPlaylist()
        }
        .onChange(of: theme.bgTintEnabled) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: theme.bgMediaType) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.neuralUpscaleModelToken) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .confirmationDialog(
            SakuraL10n.tr("ui.dialog.resetThemeTitle"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(SakuraL10n.tr("common.reset"), role: .destructive) {
                theme.resetAllToDefaults()
            }
            Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(SakuraL10n.tr("ui.dialog.resetThemeMessage"))
        }
        .confirmationDialog(SakuraL10n.tr("ui.dialog.backgroundImageTitle"), isPresented: $showBackdropImageSourceDialog, titleVisibility: .visible) {
            Button(SakuraL10n.tr("common.photoLibrary")) { showBackdropImageImporter = true }
            Button(SakuraL10n.tr("common.files")) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    showBackdropImageFileImporter = true
                }
            }
            if theme.bgMediaType == "image" {
                Button(SakuraL10n.tr("common.remove"), role: .destructive) {
                    clearCustomBackdropMedia()
                }
            }
            Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(SakuraL10n.tr("ui.dialog.backgroundVideoTitle"), isPresented: $showBackdropVideoSourceDialog, titleVisibility: .visible) {
            Button(SakuraL10n.tr("common.photoLibrary")) { showBackdropVideoImporter = true }
            Button(SakuraL10n.tr("common.files")) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    showBackdropVideoFileImporter = true
                }
            }
            if theme.bgMediaType == "video" {
                Button(SakuraL10n.tr("common.remove"), role: .destructive) {
                    clearCustomBackdropMedia()
                }
            }
            Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showBackdropImageFileImporter,
            allowedContentTypes: ThemeManager.backdropImageFileImporterTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                handleFilesBackdrop(url, type: "image")
            case .failure(let err):
                SakuraLogUnified("Theme", "Warning", "Backdrop image file import: \(err.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $showBackdropVideoFileImporter,
            allowedContentTypes: ThemeManager.backdropVideoFileImporterTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                handleFilesBackdrop(url, type: "video")
            case .failure(let err):
                SakuraLogUnified("Theme", "Warning", "Backdrop video file import: \(err.localizedDescription)")
            }
        }
        .photosPicker(
            isPresented: $showBackdropImageImporter,
            selection: $backdropImageSelection,
            matching: .images
        )
        .photosPicker(
            isPresented: $showBackdropVideoImporter,
            selection: $backdropVideoSelection,
            matching: .videos
        )
        .onChange(of: backdropImageSelection) { _, newValue in
            guard let item = newValue else { return }
            Task { await handlePhotosBackdrop(item, type: "image") }
        }
        .onChange(of: backdropVideoSelection) { _, newValue in
            guard let item = newValue else { return }
            Task { await handlePhotosBackdrop(item, type: "video") }
        }
    }

    // MARK: - Photos backdrop import

    @MainActor
    private func handlePhotosBackdrop(_ item: PhotosPickerItem, type: String) async {
        defer {
            if type == "image" { backdropImageSelection = nil }
            else { backdropVideoSelection = nil }
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                SakuraLogUnified("Theme", "Warning", "Backdrop photos load returned nil")
                return
            }
            let ext: String = {
                if type == "video" { return "mov" }
                if data.count >= 4 {
                    let b = [UInt8](data.prefix(4))
                    if b[0] == 0x89 && b[1] == 0x50 { return "png" }
                    if b[0] == 0xFF && b[1] == 0xD8 { return "jpg" }
                }
                return "jpg"
            }()
            let stamp = Int(Date().timeIntervalSince1970)
            let safeName = "\(stamp)-photos.\(ext)"
            let dest = ThemeManager.backgroundMediaDir.appendingPathComponent(safeName)
            try? FileManager.default.createDirectory(at: ThemeManager.backgroundMediaDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try data.write(to: dest)
            BackgroundVideo.shared.teardown()
            theme.bgMediaFilename = safeName
            theme.bgMediaType = type
            SakuraLogUnified("Theme", "Info", "Imported backdrop \(type) from Photos: \(safeName)")
        } catch {
            SakuraLogUnified("Theme", "Warning", "Backdrop Photos import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.appearance")) {
            TileGrid {
                ColorSwatchGrid(
                    title: SakuraL10n.tr("ui.theme.accentColor"),
                    icon: "paintpalette.fill",
                    selectedKey: Binding(
                        get: { theme.accentKey },
                        set: { theme.accentKey = $0 }
                    ),
                    id: "theme.accent"
                )
                CycleTile(
                    id: "theme.colorScheme",
                    icon: "circle.lefthalf.filled",
                    title: SakuraL10n.tr("ui.theme.colorSchemeTile"),
                    options: colorSchemeCycleOptions(),
                    selection: Binding(
                        get: { theme.colorSchemeKey },
                        set: { theme.colorSchemeKey = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.boxyCorners",
                    icon: "square",
                    title: SakuraL10n.tr("ui.theme.boxyCorners"),
                    isOn: Binding(
                        get: { theme.boxyCorners },
                        set: { theme.boxyCorners = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.glassAccent",
                    icon: "sparkles",
                    title: SakuraL10n.tr("ui.theme.glassAccent"),
                    isOn: Binding(
                        get: { theme.glassAccent },
                        set: { theme.glassAccent = $0 }
                    )
                )
                SliderTile(
                    id: "theme.menuTransparency",
                    icon: "rectangle.on.rectangle",
                    title: SakuraL10n.tr("ui.theme.menuTransparency"),
                    value: Binding(
                        get: { theme.menuTransparency },
                        set: { theme.menuTransparency = $0 }
                    ),
                    range: 0...1,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }
        }
    }

    private var upscaleArtSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.upscaleArt")) {
            TileGrid {
                ToggleTile(
                    id: "theme.neuralTextureArt",
                    icon: "photo.artframe",
                    title: SakuraL10n.tr("ui.theme.neuralTextureArtTile"),
                    isOn: $settings.neuralUpscaleTextureArt
                )
            }
        }
    }

    // MARK: - Background

    private var backgroundSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.background")) {
            TileGrid {
                CycleTile(
                    id: "theme.backdrop",
                    icon: "circle.lefthalf.filled",
                    title: SakuraL10n.tr("theme.backdrop.tile"),
                    options: backdropCycleOptions(),
                    selection: Binding(
                        get: { theme.backdropKey },
                        set: { theme.backdropKey = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.bgTintEnabled",
                    icon: "drop.fill",
                    title: SakuraL10n.tr("theme.bgTint.tile"),
                    isOn: Binding(
                        get: { theme.bgTintEnabled },
                        set: { theme.bgTintEnabled = $0 }
                    )
                )
                SliderTile(
                    id: "theme.bgTintStrength",
                    icon: "slider.horizontal.below.rectangle",
                    title: SakuraL10n.tr("theme.bgTintStrength.tile"),
                    value: Binding(
                        get: { theme.bgTintStrength },
                        set: { theme.bgTintStrength = $0 }
                    ),
                    range: 0...1,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                if theme.bgTintEnabled {
                    ColorSwatchGrid(
                        title: SakuraL10n.tr("theme.bgTint.top"),
                        icon: "drop",
                        selectedKey: Binding(
                            get: { theme.bgTintKey },
                            set: { theme.bgTintKey = $0 }
                        ),
                        id: "theme.bgTint"
                    )
                    ColorSwatchGrid(
                        title: SakuraL10n.tr("theme.bgTint.bottom"),
                        icon: "drop.fill",
                        selectedKey: Binding(
                            get: { theme.bgTintKey2 },
                            set: { theme.bgTintKey2 = $0 }
                        ),
                        id: "theme.bgTint2"
                    )
                }

                SettingTile(
                    id: "theme.bgMediaImage",
                    icon: "photo.on.rectangle.angled",
                    title: SakuraL10n.tr("theme.bgMedia.imageTile"),
                    value: backgroundMediaValueText(for: "image"),
                    valueTint: theme.bgMediaType == "image" ? theme.color(forKey: "green") : theme.glassTextPrimary(colorScheme)
                ) {
                    showBackdropImageSourceDialog = true
                }

                SettingTile(
                    id: "theme.bgMediaVideo",
                    icon: "film.fill",
                    title: SakuraL10n.tr("theme.bgMedia.videoTile"),
                    value: backgroundMediaValueText(for: "video"),
                    valueTint: theme.bgMediaType == "video" ? theme.color(forKey: "green") : theme.glassTextPrimary(colorScheme)
                ) {
                    showBackdropVideoSourceDialog = true
                }

                if theme.bgMediaType != "none" {
                    SliderTile(
                        id: "theme.bgMediaOpacity",
                        icon: "circle.righthalf.filled",
                        title: SakuraL10n.tr("theme.bgMedia.opacityTile"),
                        value: Binding(
                            get: { theme.bgMediaOpacity },
                            set: { theme.bgMediaOpacity = $0 }
                        ),
                        range: 0...1,
                        step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                }
            }
        }
    }

    private func clearCustomBackdropMedia() {
        if let url = theme.backgroundMediaURL() {
            try? FileManager.default.removeItem(at: url)
        }
        theme.bgMediaType = "none"
        theme.bgMediaFilename = ""
        BackgroundVideo.shared.teardown()
    }

    private func handleFilesBackdrop(_ url: URL, type: String) {
        do {
            let safeName = try ThemeManager.importBackdropFromFilesPicker(url, type: type)
            BackgroundVideo.shared.teardown()
            theme.bgMediaFilename = safeName
            theme.bgMediaType = type
            SakuraLogUnified("Theme", "Info", "Imported backdrop \(type) from Files: \(safeName)")
        } catch {
            SakuraLogUnified("Theme", "Warning", "Backdrop Files import failed: \(error.localizedDescription)")
        }
    }

    private func backgroundMediaValueText(for type: String) -> String {
        guard theme.bgMediaType == type, !theme.bgMediaFilename.isEmpty else {
            return SakuraL10n.tr("theme.bgMedia.photosOrFiles")
        }
        let name = theme.bgMediaFilename
        let logical = ThemeManager.normalizedBackdropFilename(name)
        if type == "video", ThemeManager.isCherryBlossomsBackdrop(name) {
            return SakuraL10n.tr("theme.bgMedia.cherryBlossoms")
        }
        if let dash = logical.firstIndex(of: "-") {
            return String(logical[logical.index(after: dash)...])
        }
        return logical
    }

    // MARK: - Library Theme

    private var librarySection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.libraryTheme")) {
            TileGrid {
                CycleTile(
                    id: "theme.libraryFontFamily",
                    icon: "textformat",
                    title: SakuraL10n.tr("typography.fontFamily"),
                    options: typographyFontOptions(),
                    selection: Binding(
                        get: { theme.libraryFontFamilyKey },
                        set: { theme.libraryFontFamilyKey = $0 }
                    )
                )
                CycleTile(
                    id: "theme.libraryFontWeight",
                    icon: "bold",
                    title: SakuraL10n.tr("typography.fontWeightTile"),
                    options: typographyWeightOptions(),
                    selection: Binding(
                        get: { theme.libraryFontWeightKey },
                        set: { theme.libraryFontWeightKey = $0 }
                    )
                )
                SliderTile(
                    id: "theme.libraryTextScale",
                    icon: "textformat.size",
                    title: SakuraL10n.tr("typography.textScale"),
                    value: Binding(
                        get: { theme.libraryTextScale },
                        set: { theme.libraryTextScale = $0 }
                    ),
                    range: 0.85...1.3,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("typography.textColorTile"),
                    icon: "textformat",
                    selectedKey: Binding(
                        get: { theme.libraryTextColorKey },
                        set: { theme.libraryTextColorKey = $0 }
                    ),
                    id: "theme.libraryTextColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("typography.captionColorTile"),
                    icon: "textformat.size",
                    selectedKey: Binding(
                        get: { theme.libraryCaptionColorKey },
                        set: { theme.libraryCaptionColorKey = $0 }
                    ),
                    id: "theme.libraryCaptionColor"
                )
                CycleTile(
                    id: "theme.gridSize",
                    icon: "square.grid.3x3",
                    title: SakuraL10n.tr("theme.grid.tileSize"),
                    options: gridSizeCycleOptions(),
                    selection: Binding(
                        get: { theme.gridSizeKey },
                        set: { theme.gridSizeKey = $0 }
                    )
                )
                SliderTile(
                    id: "theme.gridSpacing",
                    icon: "rectangle.3.group",
                    title: SakuraL10n.tr("theme.grid.spacing"),
                    value: Binding(
                        get: { theme.gridSpacing },
                        set: { theme.gridSpacing = $0 }
                    ),
                    range: 4...28,
                    step: 1,
                    format: { String(format: "%.0f", $0) }
                )
            }
        }
    }

    private var settingsSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.settingsTheme")) {
            TileGrid {
                CycleTile(
                    id: "theme.settingsFontFamily",
                    icon: "textformat",
                    title: SakuraL10n.tr("typography.fontFamily"),
                    options: typographyFontOptions(),
                    selection: Binding(
                        get: { theme.settingsFontFamilyKey },
                        set: { theme.settingsFontFamilyKey = $0 }
                    )
                )
                CycleTile(
                    id: "theme.settingsFontWeight",
                    icon: "bold",
                    title: SakuraL10n.tr("typography.fontWeightTile"),
                    options: typographyWeightOptions(),
                    selection: Binding(
                        get: { theme.settingsFontWeightKey },
                        set: { theme.settingsFontWeightKey = $0 }
                    )
                )
                SliderTile(
                    id: "theme.settingsTextScale",
                    icon: "textformat.size",
                    title: SakuraL10n.tr("typography.textScale"),
                    value: Binding(
                        get: { theme.settingsTextScale },
                        set: { theme.settingsTextScale = $0 }
                    ),
                    range: 0.85...1.3,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("typography.textColorTile"),
                    icon: "textformat",
                    selectedKey: Binding(
                        get: { theme.settingsTextColorKey },
                        set: { theme.settingsTextColorKey = $0 }
                    ),
                    id: "theme.settingsTextColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("typography.captionColorTile"),
                    icon: "textformat.size",
                    selectedKey: Binding(
                        get: { theme.settingsCaptionColorKey },
                        set: { theme.settingsCaptionColorKey = $0 }
                    ),
                    id: "theme.settingsCaptionColor"
                )
            }
        }
    }

    // MARK: - Top bar & bottom bar

    private var topBarSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.topBottomBar")) {
            TileGrid {
                ToggleTile(
                    id: "ui.topbar.battery",
                    icon: "battery.75",
                    title: SakuraL10n.tr("ui.tile.hideBattery"),
                    isOn: Binding(
                        get: { settings.topBarHideBattery },
                        set: { settings.topBarHideBattery = $0 }
                    )
                )
                ToggleTile(
                    id: "ui.topbar.music",
                    icon: "music.note",
                    title: SakuraL10n.tr("ui.tile.hideMusicPlayer"),
                    isOn: Binding(
                        get: { settings.topBarHideMusic },
                        set: { settings.topBarHideMusic = $0 }
                    )
                )
                ToggleTile(
                    id: "ui.bottombar.hidden",
                    icon: "rectangle.bottomhalf.filled",
                    title: SakuraL10n.tr("ui.tile.hideBottomIcons"),
                    isOn: Binding(
                        get: { settings.bottomActionBarHidden },
                        set: { settings.bottomActionBarHidden = $0 }
                    )
                )
                ToggleTile(
                    id: "ui.confirmStop",
                    icon: "hand.raised.fill",
                    title: SakuraL10n.tr("ui.tile.confirmStop"),
                    isOn: Binding(
                        get: { settings.emuMenuConfirmOnStop },
                        set: { settings.emuMenuConfirmOnStop = $0 }
                    )
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("ui.tile.topBar.wordmarkTint"),
                    icon: "textformat",
                    selectedKey: Binding(
                        get: { theme.topBarTextColorKey },
                        set: { theme.topBarTextColorKey = $0 }
                    ),
                    id: "theme.topBarText"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("ui.tile.topBar.captionTint"),
                    icon: "textformat.size.smaller",
                    selectedKey: Binding(
                        get: { theme.topBarCaptionColorKey },
                        set: { theme.topBarCaptionColorKey = $0 }
                    ),
                    id: "theme.topBarCaption"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("ui.tile.topBar.accentTint"),
                    icon: "battery.75",
                    selectedKey: Binding(
                        get: { theme.topBarAccentColorKey },
                        set: { theme.topBarAccentColorKey = $0 }
                    ),
                    id: "theme.topBarAccent"
                )
            }
        }
    }

    private var hudSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.hudAppearance")) {
            TileGrid {
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.hud.textSwatch"),
                    icon: "text.alignleft",
                    selectedKey: Binding(
                        get: { theme.hudColorKey },
                        set: { theme.hudColorKey = $0 }
                    ),
                    id: "theme.hudColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.hud.labelSwatch"),
                    icon: "tag",
                    selectedKey: Binding(
                        get: { theme.hudLabelColorKey },
                        set: { theme.hudLabelColorKey = $0 }
                    ),
                    id: "theme.hudLabelColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.hud.valueSwatch"),
                    icon: "number",
                    selectedKey: Binding(
                        get: { theme.hudValueColorKey },
                        set: { theme.hudValueColorKey = $0 }
                    ),
                    id: "theme.hudValueColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.hud.graphSwatch"),
                    icon: "chart.line.uptrend.xyaxis",
                    selectedKey: Binding(
                        get: { theme.hudGraphColorKey },
                        set: { theme.hudGraphColorKey = $0 }
                    ),
                    id: "theme.hudGraphColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.hud.tileFillSwatch"),
                    icon: "square.fill",
                    selectedKey: Binding(
                        get: { theme.hudTileColorKey },
                        set: { theme.hudTileColorKey = $0 }
                    ),
                    id: "theme.hudTileColor"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.hud.strokeSwatch"),
                    icon: "square",
                    selectedKey: Binding(
                        get: { theme.hudStrokeColorKey },
                        set: { theme.hudStrokeColorKey = $0 }
                    ),
                    id: "theme.hudStrokeColor"
                )
                SliderTile(
                    id: "theme.hudOpacity",
                    icon: "circle.lefthalf.filled",
                    title: SakuraL10n.tr("theme.hud.opacityTile"),
                    value: Binding(
                        get: { theme.hudOpacity },
                        set: { theme.hudOpacity = $0 }
                    ),
                    range: 0.2...1,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SliderTile(
                    id: "theme.hudScale",
                    icon: "plus.magnifyingglass",
                    title: SakuraL10n.tr("theme.hud.scaleTile"),
                    value: Binding(
                        get: { theme.hudScale },
                        set: { theme.hudScale = $0 }
                    ),
                    range: 0.7...1.6,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SliderTile(
                    id: "theme.hudCornerRadius",
                    icon: "squareshape.squareshape.dotted",
                    title: SakuraL10n.tr("theme.hud.cornerTile"),
                    value: Binding(
                        get: { theme.hudCornerRadius },
                        set: { theme.hudCornerRadius = $0 }
                    ),
                    range: 0...24,
                    step: 1,
                    format: { String(format: "%.0f", $0) }
                )
                CycleTile(
                    id: "theme.hudFontFamily",
                    icon: "textformat.abc",
                    title: SakuraL10n.tr("theme.hud.fontTile"),
                    options: hudFontCycleOptions(),
                    selection: Binding(
                        get: { theme.hudFontFamilyKey },
                        set: { theme.hudFontFamilyKey = $0 }
                    )
                )
                SliderTile(
                    id: "theme.hudGraphLineWidth",
                    icon: "line.diagonal",
                    title: SakuraL10n.tr("theme.hud.graphLineTile"),
                    value: Binding(
                        get: { theme.hudGraphLineWidth },
                        set: { theme.hudGraphLineWidth = $0 }
                    ),
                    range: 0.5...3,
                    step: 0.1,
                    format: { String(format: "%.1f", $0) }
                )
            }
        }
    }

    private var inGameMenuChromeSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.ingameMenuChrome")) {
            TileGrid {
                ToggleTile(
                    id: "theme.inGameMenuLite",
                    icon: "rectangle.lefthalf.inset.filled",
                    title: SakuraL10n.tr("theme.ingame.liteMode"),
                    isOn: Binding(
                        get: { theme.inGameMenuUsesLiteChrome },
                        set: { theme.inGameMenuUsesLiteChrome = $0 }
                    )
                )
                SliderTile(
                    id: "theme.inGameMenuDim",
                    icon: "moon.fill",
                    title: SakuraL10n.tr("theme.ingame.dimOpacity"),
                    value: Binding(
                        get: { theme.inGameMenuScrimOpacity },
                        set: { theme.inGameMenuScrimOpacity = $0 }
                    ),
                    range: 0...1,
                    step: 0.02,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SliderTile(
                    id: "theme.inGameMenuCorner",
                    icon: "squareshape",
                    title: SakuraL10n.tr("theme.ingame.cornerRadius"),
                    value: Binding(
                        get: { theme.inGameMenuCornerRadius },
                        set: { theme.inGameMenuCornerRadius = $0 }
                    ),
                    range: 0...32,
                    step: 1,
                    format: { String(format: "%.0f", $0) }
                )
                SliderTile(
                    id: "theme.inGameMenuStrokeOp",
                    icon: "square.dashed",
                    title: SakuraL10n.tr("theme.ingame.strokeOpacity"),
                    value: Binding(
                        get: { theme.inGameMenuStrokeOpacity },
                        set: { theme.inGameMenuStrokeOpacity = $0 }
                    ),
                    range: 0...1,
                    step: 0.02,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                SliderTile(
                    id: "theme.inGameMenuStrokeW",
                    icon: "line.diagonal",
                    title: SakuraL10n.tr("theme.ingame.strokeWidth"),
                    value: Binding(
                        get: { theme.inGameMenuStrokeWidth },
                        set: { theme.inGameMenuStrokeWidth = $0 }
                    ),
                    range: 0...3,
                    step: 0.1,
                    format: { String(format: "%.1f", $0) }
                )
                SliderTile(
                    id: "theme.inGameMenuShadow",
                    icon: "shadow",
                    title: SakuraL10n.tr("theme.ingame.shadowRadius"),
                    value: Binding(
                        get: { theme.inGameMenuShadowRadius },
                        set: { theme.inGameMenuShadowRadius = $0 }
                    ),
                    range: 0...30,
                    step: 1,
                    format: { String(format: "%.0f", $0) }
                )
                SliderTile(
                    id: "theme.inGameTopBarOp",
                    icon: "rectangle.topthird.inset.filled",
                    title: SakuraL10n.tr("theme.ingame.topBarOpacity"),
                    value: Binding(
                        get: { theme.inGameTopBarOpacity },
                        set: { theme.inGameTopBarOpacity = $0 }
                    ),
                    range: 0...1,
                    step: 0.02,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.sectionHeaderColor"),
                    icon: "text.book.closed",
                    selectedKey: Binding(
                        get: { theme.inGameMenuHeaderColorKey },
                        set: { theme.inGameMenuHeaderColorKey = $0 }
                    ),
                    id: "theme.inGameMenuHeader"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.sectionBubbleColor"),
                    icon: "square.fill.on.circle.fill",
                    selectedKey: Binding(
                        get: { theme.inGameMenuBubbleColorKey },
                        set: { theme.inGameMenuBubbleColorKey = $0 }
                    ),
                    id: "theme.inGameMenuBubble"
                )
                SliderTile(
                    id: "theme.inGameMenuBubbleFill",
                    icon: "square.on.square.dashed",
                    title: SakuraL10n.tr("theme.ingame.sectionBubbleFill"),
                    value: Binding(
                        get: { theme.inGameMenuBubbleFillOpacity },
                        set: { theme.inGameMenuBubbleFillOpacity = $0 }
                    ),
                    range: 0.04...0.48,
                    step: 0.02,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.rowIconColor"),
                    icon: "leaf",
                    selectedKey: Binding(
                        get: { theme.inGameMenuIconColorKey },
                        set: { theme.inGameMenuIconColorKey = $0 }
                    ),
                    id: "theme.inGameMenuIcon"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.panelOutlineColor"),
                    icon: "rectangle.dashed",
                    selectedKey: Binding(
                        get: { theme.inGameMenuOuterStrokeColorKey },
                        set: { theme.inGameMenuOuterStrokeColorKey = $0 }
                    ),
                    id: "theme.inGameMenuOuterStroke"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.textColorSwatch"),
                    icon: "textformat",
                    selectedKey: Binding(
                        get: { theme.inGameMenuTextColorKey },
                        set: { theme.inGameMenuTextColorKey = $0 }
                    ),
                    id: "theme.inGameMenuText"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.captionColorSwatch"),
                    icon: "textformat.size",
                    selectedKey: Binding(
                        get: { theme.inGameMenuCaptionColorKey },
                        set: { theme.inGameMenuCaptionColorKey = $0 }
                    ),
                    id: "theme.inGameMenuCaption"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.ingame.accentSwatch"),
                    icon: "paintpalette.fill",
                    selectedKey: Binding(
                        get: { theme.inGameMenuAccentColorKey },
                        set: { theme.inGameMenuAccentColorKey = $0 }
                    ),
                    id: "theme.inGameMenuAccent"
                )
            }
        }
    }

    private var notificationsSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.notificationTheme")) {
            TileGrid {
                CycleTile(
                    id: "theme.notificationFontFamily",
                    icon: "textformat",
                    title: SakuraL10n.tr("theme.notifications.fontFamilyTile"),
                    options: typographyFontOptions(),
                    selection: Binding(
                        get: { theme.notificationFontFamilyKey },
                        set: { theme.notificationFontFamilyKey = $0 }
                    )
                )
                CycleTile(
                    id: "theme.notificationFontWeight",
                    icon: "bold",
                    title: SakuraL10n.tr("theme.notifications.fontWeightTile"),
                    options: typographyWeightOptions(),
                    selection: Binding(
                        get: { theme.notificationFontWeightKey },
                        set: { theme.notificationFontWeightKey = $0 }
                    )
                )
                SliderTile(
                    id: "theme.notificationTextScale",
                    icon: "textformat.size",
                    title: SakuraL10n.tr("theme.notifications.textScaleTile"),
                    value: Binding(
                        get: { theme.notificationTextScale },
                        set: { theme.notificationTextScale = $0 }
                    ),
                    range: 0.85...1.3,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.notifications.tintTile"),
                    icon: "bell.fill",
                    selectedKey: Binding(
                        get: { theme.notificationTintKey },
                        set: { theme.notificationTintKey = $0 }
                    ),
                    id: "theme.notifTint"
                )
                ColorSwatchGrid(
                    title: SakuraL10n.tr("theme.notifications.controllerTintTile"),
                    icon: "gamecontroller.fill",
                    selectedKey: Binding(
                        get: { theme.controllerNotificationTintKey },
                        set: { theme.controllerNotificationTintKey = $0 }
                    ),
                    id: "theme.ctrlNotifTint"
                )
            }
        }
    }

    private var accessibilitySection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.accessibility")) {
            TileGrid {
                ToggleTile(
                    id: "theme.reduceMotion",
                    icon: "hare",
                    title: SakuraL10n.tr("ui.theme.reduceMotion"),
                    isOn: Binding(
                        get: { theme.reduceMotion },
                        set: { theme.reduceMotion = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.increaseContrast",
                    icon: "circle.righthalf.filled",
                    title: SakuraL10n.tr("ui.theme.increaseContrast"),
                    isOn: Binding(
                        get: { theme.increaseContrast },
                        set: { theme.increaseContrast = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.differentiateWithoutColor",
                    icon: "eye",
                    title: SakuraL10n.tr("ui.theme.shapeCues"),
                    isOn: Binding(
                        get: { theme.differentiateWithoutColor },
                        set: { theme.differentiateWithoutColor = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.reduceTransparency",
                    icon: "square.fill.on.square.fill",
                    title: SakuraL10n.tr("ui.theme.reduceTransparency"),
                    isOn: Binding(
                        get: { theme.reduceTransparency },
                        set: { theme.reduceTransparency = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.largerTouchTargets",
                    icon: "hand.tap.fill",
                    title: SakuraL10n.tr("ui.theme.largerTouchTargets"),
                    isOn: Binding(
                        get: { theme.largerTouchTargets },
                        set: { theme.largerTouchTargets = $0 }
                    )
                )
                ToggleTile(
                    id: "theme.highContrastOutlines",
                    icon: "square.on.square.dashed",
                    title: SakuraL10n.tr("ui.theme.highContrastOutlines"),
                    isOn: Binding(
                        get: { theme.highContrastOutlines },
                        set: { theme.highContrastOutlines = $0 }
                    )
                )
                CycleTile(
                    id: "theme.hapticIntensity",
                    icon: "waveform",
                    title: SakuraL10n.tr("ui.theme.hapticIntensity"),
                    options: hapticIntensityCycleOptions(),
                    selection: Binding(
                        get: { theme.hapticIntensityKey },
                        set: { theme.hapticIntensityKey = $0 }
                    )
                )
                SliderTile(
                    id: "theme.holdToPress",
                    icon: "timer",
                    title: SakuraL10n.tr("ui.theme.holdToPress"),
                    value: Binding(
                        get: { theme.holdToPressMs },
                        set: { theme.holdToPressMs = $0 }
                    ),
                    range: 0...400,
                    step: 10,
                    format: { v in v <= 0 ? SakuraL10n.tr("common.off") : String(format: "%.0f ms", v) }
                )
            }
        }
    }

    private var sfxSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.soundEffects")) {
            TileGrid {
                ToggleTile(
                    id: "theme.sfxEnabled",
                    icon: "speaker.wave.2.fill",
                    title: SakuraL10n.tr("ui.theme.soundEffectsEnabled"),
                    isOn: Binding(
                        get: { SFXManager.shared.enabled },
                        set: { SFXManager.shared.enabled = $0 }
                    )
                )
                SliderTile(
                    id: "theme.sfxVolume",
                    icon: "speaker.fill",
                    title: SakuraL10n.tr("ui.theme.soundEffectsVolumeTile"),
                    value: Binding(
                        get: { Double(SFXManager.shared.volume) },
                        set: { SFXManager.shared.volume = Float($0) }
                    ),
                    range: 0...1,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
            }
        }
    }

    private var resetSection: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.resetAppearance")) {
            DestructiveTile(
                id: "theme.reset",
                icon: "arrow.counterclockwise",
                title: SakuraL10n.tr("ui.theme.resetToDefaultsDestructive")
            ) {
                showResetConfirm = true
            }
        }
    }
}
