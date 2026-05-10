// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings shell

struct SettingsRootView: View {
    @State private var appState = AppState.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var tileFocus = TileFocus.shared
    @AppStorage(AppLocale.appStorageKey) private var localeOverrideRaw = ""
    @State private var selectedTopIndex = AppState.shared.selectedSettingsPage.rawValue + 2
    @State private var showImportPicker = false
    @State private var theme = ThemeManager.shared
    @State private var settings = SettingsStore.shared
    @Environment(\.sakuraRenderingOnExternalDisplay) private var onTV

    private func dynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        if scale < 0.9 { return .small }
        if scale < 1.0 { return .medium }
        if scale < 1.1 { return .large }
        if scale < 1.2 { return .xLarge }
        if scale < 1.3 { return .xxLarge }
        return .xxxLarge
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(
                selectedIndex: $selectedTopIndex,
                controllerFocusActive: gamepad.shellNavInputActive && tileFocus.region == .topBar,
                wideChrome: onTV,
                leadingTitle: appState.selectedSettingsPage.title,
                activateItem: activateTopBarSelection
            )

            settingsView(for: appState.selectedSettingsPage)
                .id("\(localeOverrideRaw)-\(appState.selectedSettingsPage.id)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fontDesign(theme.settingsFontDesign())
                .fontWeight(theme.settingsFontWeight())
                .environment(\.dynamicTypeSize, dynamicTypeSize(for: theme.settingsTextScale))

            if !settings.bottomActionBarHidden {
                settingsControllerHintCapsule
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .onAppear {
            gamepad.enterSettings()
            syncTopBarSelection()
            tileFocus.enterContent()
        }
        .onChange(of: appState.selectedSettingsPage) { _, _ in
            syncTopBarSelection()
        }
        .onChange(of: gamepad.actionID) { _, _ in
            guard gamepad.context == .settings else { return }
            handleGamepadAction()
        }
        .onChange(of: gamepad.isActive) { _, _ in
            syncSettingsKeyboardNavFocus()
        }
        .onChange(of: gamepad.hasHardwareKeyboard) { _, _ in
            syncSettingsKeyboardNavFocus()
        }
        .onDisappear {
            gamepad.leave(.settings)
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: FileImporterTypes.settingsGameImports,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    FileImportHandler.shared.handleURL(url)
                }
            case .failure(let err):
                SakuraLogUnified("UI", "Warning", "import picker failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Page routing

    @ViewBuilder
    private func settingsView(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralSettingsView()
        case .graphics:
            GraphicsSettingsView()
        case .osd:
            OSDSettingsView()
        case .controller:
            ControllerSettingsView()
        case .ui:
            UISettingsView()
        case .about:
            AboutHelpView()
        }
    }

    @ViewBuilder
    private var settingsControllerHintCapsule: some View {
        let kb = gamepad.hasHardwareKeyboard
        HStack(alignment: .center, spacing: 8) {
            PSActionBadge(
                systemName: "l1.button.roundedbottom.horizontal",
                psIcon: nil,
                psFallback: nil,
                circleGlyphText: kb ? SakuraL10n.tr("keyboard.shell.brackets") : nil,
                shoulderSymbol: kb ? nil : "l1.button.roundedbottom.horizontal",
                shoulderSymbolSecond: kb ? nil : "r1.button.roundedbottom.horizontal",
                title: SakuraL10n.tr("library.hint.pages"),
                tint: theme.color(forKey: "yellow"),
                libraryFooterCompact: true
            )
            PSActionBadge(
                systemName: "checkmark",
                psIcon: kb ? nil : "cross",
                psFallback: kb ? SakuraL10n.tr("keyboard.shell.enter") : gamepad.confirmLabel,
                title: SakuraL10n.tr("settings.controllerHint.confirm"),
                tint: theme.color(forKey: "blue"),
                libraryFooterCompact: true
            )
            PSActionBadge(
                systemName: "chevron.backward",
                psIcon: kb ? nil : "circle",
                psFallback: kb ? SakuraL10n.tr("keyboard.shell.esc") : gamepad.backLabel,
                title: SakuraL10n.tr("settings.controllerHint.library"),
                tint: theme.color(forKey: "red"),
                libraryFooterCompact: true
            )
            PSActionBadge(
                systemName: "line.3.horizontal",
                psIcon: nil,
                psFallback: nil,
                circleGlyphText: kb ? SakuraL10n.tr("keyboard.shell.m") : nil,
                title: SakuraL10n.tr("settings.controllerHint.import"),
                tint: theme.glassTextPrimary(.dark),
                libraryFooterCompact: true
            )
        }
    }

    private func syncSettingsKeyboardNavFocus() {
        guard gamepad.shellNavInputActive, tileFocus.region != .content else { return }
        tileFocus.enterContent()
    }

    private func syncTopBarSelection() {
        if selectedTopIndex > 1 {
            selectedTopIndex = appState.selectedSettingsPage.rawValue + 2
        }
    }

    private func moveTopSelection(delta: Int) {
        let count = SettingsPage.allCases.count + 2
        let nextIndex = (selectedTopIndex + delta + count) % count
        guard nextIndex != selectedTopIndex else { return }
        selectedTopIndex = nextIndex
        SFXManager.shared.play(.navigate)
    }

    private func activateTopBarSelection(_ index: Int) {
        if tileFocus.isCapturing {
            return
        }
        if index == 0 {
            appState.returnToMenu()
            return
        }
        if index == 1 {
            appState.openMedia()
            return
        }

        let pageIndex = min(max(index - 2, 0), SettingsPage.allCases.count - 1)
        var txn = Transaction()
        txn.animation = nil
        withTransaction(txn) {
            appState.selectedSettingsPage = SettingsPage.allCases[pageIndex]
        }
    }

    private func handleGamepadAction() {
        guard let action = gamepad.lastAction else { return }

        if tileFocus.isCapturing {
            if action == .captureCancel {
                SFXManager.shared.play(.back)
                NotificationCenter.default.post(
                    name: NSNotification.Name("SakuraControllerCaptureCancel"),
                    object: nil
                )
            }
            return
        }

        switch action {
        case .moveLeft:
            if tileFocus.isEditingSlider {
                tileFocus.requestSliderNudge(-1)
            } else if tileFocus.region == .content {
                tileFocus.move(-1)
            } else {
                moveTopSelection(delta: -1)
            }
        case .moveRight:
            if tileFocus.isEditingSlider {
                tileFocus.requestSliderNudge(1)
            } else if tileFocus.region == .content {
                tileFocus.move(1)
            } else {
                moveTopSelection(delta: 1)
            }
        case .moveUp:
            if tileFocus.region == .content {
                if !tileFocus.moveRow(-1) {
                    tileFocus.exitToTopBar()
                }
            }
        case .moveDown:
            if tileFocus.region == .topBar {
                tileFocus.enterContent()
                SFXManager.shared.play(.navigate)
            } else {
                tileFocus.moveRow(1)
            }
        case .confirm:
            if tileFocus.region == .content {
                tileFocus.confirm()
            } else {
                SFXManager.shared.play(.confirm)
                activateTopBarSelection(selectedTopIndex)
            }
        case .back:
            if tileFocus.isEditingSlider {
                tileFocus.isEditingSlider = false
                SFXManager.shared.play(.back)
            } else if tileFocus.region == .content {
                tileFocus.exitToTopBar()
            } else {
                SFXManager.shared.play(.back)
                appState.returnToMenu()
            }
        case .menu:
            SFXManager.shared.play(.confirm)
            showImportPicker = true
        case .shoulderLeft:
            SFXManager.shared.play(.navigate)
            appState.cycleTopSection(delta: -1)
        case .shoulderRight:
            SFXManager.shared.play(.navigate)
            appState.cycleTopSection(delta: 1)
        case .triggerLeft, .triggerRight:
            break
        case .captureCancel, .secondary, .tertiary:
            break
        }
    }

}

