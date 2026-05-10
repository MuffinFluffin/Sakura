// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @State private var bioses: [String] = []
    @State private var defaultBIOS: String = ""
    @State private var focus = TileFocus.shared
    @Bindable private var settings = SettingsStore.shared
    @State private var theme = ThemeManager.shared
    @State private var showBIOSImporter = false
    @State private var importer = FileImportHandler.shared
    @Bindable private var neuralFetcher = NeuralUpscaleModelFetcher.shared
    @AppStorage(AppLocale.appStorageKey) private var localeOverrideRaw = ""
    @State private var showLanguagePicker = false
    @State private var pickerLocaleOverrideRaw = ""
    @Environment(\.colorScheme) private var colorScheme

    private var modelDownloadTileIDs: [String] {
        NeuralUpscaleRegistry.neuralUpscaleFetchableModels.map(\.id)
    }

    private let bootTileIDs = ["general.fastBoot"]
    private let languageTileIDs = ["general.locale"]
    private var generalSaveStateTileIDs: [String] {
        if settings.saveStatesEnabled {
            [
                "general.savestates",
                "general.saveStateOnScreenshot",
                "general.saveStateOnRecording",
                "general.screenshotOnSaveState",
                "general.saveStateBadge",
            ]
        } else {
            ["general.savestates"]
        }
    }
    private let audioTileIDs = ["general.audioTimeStretch", "general.muteTurboAudio"]
    private let performanceTileIDs = [
        "general.hostEmuSpeed",
        "general.cpuFreq", "general.cdAccess",
        "general.mainThreadMetalPresent",
    ]
    private let captureTileIDs = [
        "general.captureDestination",
        "general.captureHide",
        "general.captureTopBarSwap",
    ]

    private func tileID(for bios: String) -> String { "bios.\(bios)" }

    private var biosImportContentTypes: [UTType] {
        let exts = ["bin", "rom", "nvm", "mec", "scph"]
        var types = exts.compactMap { UTType(filenameExtension: $0) }
        types.append(.folder)
        return types.isEmpty ? [.data] : types
    }

    var body: some View {
        SettingsScroll {
            SettingSection(title: SakuraL10n.tr("general.section.boot")) {
                TileGrid {
                    ToggleTile(
                        id: "general.fastBoot",
                        icon: "bolt.circle.fill",
                        title: SakuraL10n.tr("general.tile.fastBoot"),
                        isOn: $settings.fastBoot
                    )
                }
            }

            SettingSection(title: SakuraL10n.tr("general.section.language")) {
                TileGrid {
                    languageTile
                }
            }

            SettingSection(title: SakuraL10n.tr("general.section.saveStates")) {
                TileGrid {
                    ToggleTile(
                        id: "general.savestates",
                        icon: "memorychip",
                        title: SakuraL10n.tr("general.tile.saveStates"),
                        isOn: $settings.saveStatesEnabled
                    )
                    if settings.saveStatesEnabled {
                        ToggleTile(
                            id: "general.saveStateOnScreenshot",
                            icon: "camera.metering.spot",
                            title: SakuraL10n.tr("general.tile.saveStateOnScreenshot"),
                            isOn: $settings.mediaAttachStateOnScreenshot
                        )
                        CycleTile(
                            id: "general.saveStateOnRecording",
                            icon: "video.bubble",
                            title: SakuraL10n.tr("general.tile.saveStateOnRecording"),
                            options: SettingsStore.localizedSaveStateRecordingOptions(),
                            selection: $settings.mediaAttachStateOnRecordingRaw
                        )
                        ToggleTile(
                            id: "general.screenshotOnSaveState",
                            icon: "camera.shutter.button",
                            title: SakuraL10n.tr("general.tile.screenshotOnSaveState"),
                            isOn: $settings.mediaScreenshotOnSaveState
                        )
                        ToggleTile(
                            id: "general.saveStateBadge",
                            icon: "bookmark",
                            title: SakuraL10n.tr("general.tile.saveStateBadge"),
                            isOn: $settings.mediaShowAttachedStateBadge
                        )
                    }
                }
            }

            SettingSection(title: SakuraL10n.tr("general.section.capture")) {
                TileGrid {
                    CycleTile(
                        id: "general.captureDestination",
                        icon: "square.and.arrow.down",
                        title: SakuraL10n.tr("general.capture.saveTo"),
                        options: SettingsStore.localizedCaptureDestinationOptions(),
                        selection: Binding(
                            get: { SettingsStore.normalizedCaptureDestination(forStored: settings.captureDestination) },
                            set: { settings.captureDestination = $0 }
                        )
                    )
                    CycleTile(
                        id: "general.captureHide",
                        icon: "eye.slash",
                        title: SakuraL10n.tr("general.capture.whileRecording"),
                        options: SettingsStore.localizedCaptureScopeOptions(),
                        selection: Binding(
                            get: { SettingsStore.normalizedCaptureScope(forStored: settings.captureScope) },
                            set: { settings.captureScope = $0 }
                        )
                    )
                    ToggleTile(
                        id: "general.captureTopBarSwap",
                        icon: "camera.on.rectangle",
                        title: SakuraL10n.tr("general.capture.topBarSwap"),
                        isOn: $settings.topBarSwapSpeedForRecord
                    )
                }
            }

            SettingSection(title: SakuraL10n.tr("general.section.audio")) {
                TileGrid {
                    ToggleTile(
                        id: "general.audioTimeStretch",
                        icon: "waveform.path",
                        title: SakuraL10n.tr("general.tile.timeStretch"),
                        isOn: $settings.audioTimeStretch
                    )
                    ToggleTile(
                        id: "general.muteTurboAudio",
                        icon: "speaker.slash",
                        title: SakuraL10n.tr("general.tile.muteTurbo"),
                        isOn: $settings.muteAudioWhenTurbo
                    )
                }
            }

            SettingSection(title: SakuraL10n.tr("general.section.performance")) {
                TileGrid {
                    CycleTile(
                        id: "general.hostEmuSpeed",
                        icon: "hare.fill",
                        title: SakuraL10n.tr("general.tile.speed"),
                        options: SettingsStore.localizedHostEmulationSpeedOptions(),
                        selection: $settings.hostEmulationSpeed
                    )
                    CycleTile(
                        id: "general.cpuFreq",
                        icon: "gauge.with.dots.needle.67percent",
                        title: SakuraL10n.tr("general.tile.cpuFreq"),
                        options: SettingsStore.localizedCpuFreqScaleOptions(),
                        selection: $settings.cpuFreqScale
                    )
                    CycleTile(
                        id: "general.cdAccess",
                        icon: "opticaldisc",
                        title: SakuraL10n.tr("general.tile.cdAccess"),
                        options: SettingsStore.localizedCdAccessMethodOptions(),
                        selection: $settings.cdAccessMethod
                    )
                    ToggleTile(
                        id: "general.mainThreadMetalPresent",
                        icon: "cpu.fill",
                        title: SakuraL10n.tr("general.tile.mainThreadPresent"),
                        isOn: $settings.mainThreadMetalPresentEnabled
                    )
                }
            }

            importBIOSButton

            if bioses.isEmpty {
                emptyState
            } else {
                SettingSection(title: SakuraL10n.tr("general.section.installedBios")) {
                    VStack(spacing: 8) {
                        ForEach(bioses, id: \.self) { bios in
                            biosRow(bios)
                        }
                    }
                }
            }

            modelDownloadsSection
        }
        .onAppear {
            loadBIOSes()
            updateFocusPage()
        }
        .onChange(of: bioses) { _, newValue in
            updateFocusPage(bioses: newValue)
        }
        .fileImporter(
            isPresented: $showBIOSImporter,
            allowedContentTypes: biosImportContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    FileImportHandler.shared.handleURL(url)
                }
                loadBIOSes()
            case .failure(let err):
                SakuraLogUnified("BIOS", "Warning", "BIOS import picker failed: \(err.localizedDescription)")
            }
        }
        .sheet(isPresented: $showLanguagePicker) {
            languagePickerSheet
        }
        .alert(SakuraL10n.tr("general.alert.importTitle"), isPresented: Binding(
            get: { importer.showImportAlert },
            set: { importer.showImportAlert = $0 }
        )) {
            Button(SakuraL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(importer.lastImportMessage ?? "")
        }
        .alert(SakuraL10n.tr("general.alert.neuralTitle"), isPresented: Binding(
            get: { neuralFetcher.showAlert },
            set: { neuralFetcher.showAlert = $0 }
        )) {
            Button(SakuraL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(neuralFetcher.alertMessage ?? "")
        }
    }

    private var importBIOSButton: some View {
        Button {
            SFXManager.shared.play(.confirm)
            showBIOSImporter = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accentColor())
                Text(SakuraL10n.tr("general.bios.importButtonTitle"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.accentColor().opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.accentColor().opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SakuraL10n.tr("general.bios.importA11yLabel"))
        .accessibilityHint(SakuraL10n.tr("general.bios.importA11yHint"))
    }

    private var languageTile: some View {
        SettingTile(
            id: "general.locale",
            icon: "globe",
            title: SakuraL10n.tr("general.tile.appLanguage"),
            value: currentLanguageLabel
        ) {
            openLanguagePicker()
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            openLanguagePicker()
        }
    }

    private var languagePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker(SakuraL10n.tr("general.tile.appLanguage"), selection: $pickerLocaleOverrideRaw) {
                    ForEach(AppLocale.options) { opt in
                        Text(AppLocale.localizedLanguageLabel(for: opt, overrideRaw: pickerLocaleOverrideRaw))
                            .tag(opt.id)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .navigationTitle(SakuraL10n.tr("general.tile.appLanguage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(SakuraL10n.tr("common.done")) {
                        localeOverrideRaw = pickerLocaleOverrideRaw
                        showLanguagePicker = false
                        SakuraNotificationCenter.shared.postSettingChange(title: SakuraL10n.tr("general.tile.appLanguage"), detail: currentLanguageLabel)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var languageOptions: [(value: String, label: String)] {
        AppLocale.options.map { opt in
            (opt.id, AppLocale.localizedLanguageLabel(for: opt, overrideRaw: localeOverrideRaw))
        }
    }

    private var currentLanguageLabel: String {
        languageOptions.first(where: { $0.value == localeOverrideRaw })?.label ?? SakuraL10n.tr("common.emdash")
    }

    private func openLanguagePicker() {
        focus.focusFromTouch(id: "general.locale")
        pickerLocaleOverrideRaw = localeOverrideRaw
        showLanguagePicker = true
    }

    private func biosRow(_ bios: String) -> some View {
        let isDefault = bios == defaultBIOS
        let id = tileID(for: bios)
        let isFocused = focus.focusedID == id && focus.region == .content
        let action: () -> Void = {
            SakuraBridge.setDefaultBIOS(bios)
            defaultBIOS = bios
        }
        return Button {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bios)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(regionGuess(bios))
                        .font(.caption)
                        .foregroundStyle(theme.glassTextSecondary(colorScheme))
                }

                Spacer()

                if isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(theme.accentColor())
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.glassTextTertiary(colorScheme).opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(rowBackground(isDefault: isDefault, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        rowStroke(isDefault: isDefault, isFocused: isFocused),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                action()
            }
        }
    }

    private func rowBackground(isDefault: Bool, isFocused: Bool) -> Color {
        if isFocused { return theme.glassCardFill(colorScheme, isFocused: true) }
        if isDefault { return theme.accentColor().opacity(0.15) }
        return theme.glassCardFill(colorScheme, isFocused: false)
    }

    private func rowStroke(isDefault: Bool, isFocused: Bool) -> Color {
        if isFocused { return theme.glassTextPrimary(colorScheme) }
        if isDefault { return theme.accentColor().opacity(0.5) }
        return theme.glassCardStroke(colorScheme, isFocused: false)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("general.bios.emptyTitle"))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            Text(SakuraL10n.tr("general.bios.emptySubtitle"))
                .font(.body)
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var modelDownloadsSection: some View {
        SettingSection(title: SakuraL10n.tr("general.section.neuralDownloads")) {
            TileGrid {
                ForEach(NeuralUpscaleRegistry.neuralUpscaleFetchableModels) { item in
                    SettingTile(
                        id: item.id,
                        icon: "arrow.down.circle",
                        title: SakuraL10n.tr("\(item.id).title"),
                        value: neuralFetcher.tileSubtitle(for: item.id, idle: SakuraL10n.tr("\(item.id).subtitle"))
                    ) {
                        neuralFetcher.download(item)
                    }
                }
            }
        }
    }

    private func loadBIOSes() {
        bioses = SakuraBridge.availableBIOSes()
        defaultBIOS = SakuraBridge.defaultBIOSName()
    }

    private func updateFocusPage(bioses currentBIOSes: [String]? = nil) {
        let biosIDs = (currentBIOSes ?? bioses).map { tileID(for: $0) }
        let sections: [[String]]
        if biosIDs.isEmpty {
            sections = [bootTileIDs, languageTileIDs, generalSaveStateTileIDs, captureTileIDs, audioTileIDs, performanceTileIDs, modelDownloadTileIDs]
        } else {
            sections = [bootTileIDs, languageTileIDs, generalSaveStateTileIDs, captureTileIDs, audioTileIDs, performanceTileIDs, biosIDs, modelDownloadTileIDs]
        }
        focus.setPage(sections: sections, columnHint: 3)
    }

    private func regionGuess(_ name: String) -> String {
        let upper = name.uppercased()
        if upper.contains("JP") || upper.contains("JAPAN") || upper.contains("70000") || upper.contains("50000") {
            return SakuraL10n.tr("general.bios.regionJapan")
        } else if upper.contains("US") || upper.contains("AMERICA") || upper.contains("30001") || upper.contains("39001") {
            return SakuraL10n.tr("general.bios.regionNorthAmerica")
        } else if upper.contains("EU") || upper.contains("EUROPE") || upper.contains("30004") || upper.contains("39004") {
            return SakuraL10n.tr("general.bios.regionEurope")
        }
        return SakuraL10n.tr("general.bios.regionUnknown")
    }
}
