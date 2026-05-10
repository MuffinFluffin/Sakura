// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit
import GameController

// MARK: - Emu menu surface

private struct EmuMenuSurface: ViewModifier {
    @Bindable private var chrome = ThemeManager.shared

    private func backgroundForMenuRow<Content: View>(content: Content, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                Group {
                    if chrome.inGameMenuUsesLiteChrome {
                        Color.black.opacity(chrome.inGameMenuScrimOpacity)
                    } else if chrome.materialsReduced {
                        Color.black.opacity(0.84)
                    } else {
                        Color.clear.background(.ultraThinMaterial)
                    }
                }
            )
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    chrome.inGameMenuOuterStrokeColor().opacity(chrome.inGameMenuStrokeOpacity),
                    lineWidth: chrome.inGameMenuStrokeWidth
                )
            )
            .shadow(
                color: .black.opacity(chrome.inGameMenuUsesLiteChrome ? 0.18 : 0.1),
                radius: chrome.inGameMenuShadowRadius, x: 0, y: 6
            )
    }

    func body(content: Content) -> some View {
        let radius = chrome.boxyCorners ? max(8, chrome.inGameMenuCornerRadius - 6) : chrome.inGameMenuCornerRadius
        return backgroundForMenuRow(content: content, radius: radius)
    }
}

struct InGameQuickActionsOverlay: View {
    @Bindable private var theme = ThemeManager.shared
    @ObservedObject private var assigner = ControllerPortAssigner.shared

    @Binding var isPresented: Bool
    @Binding var focusIndex: Int
    @Binding var saveStateRefreshToken: Int

    let quickLoadSlot: Int?
    var onSave: () -> Void
    var onLoad: () -> Void
    var onRemap: () -> Void
    var onMenu: () -> Void
    var onRestart: () -> Void
    var onExit: () -> Void

    private var quickMenuBodyFont: CGFloat {
        let w = UIScreen.main.bounds.width
        if w <= 320 { return 11 }
        if w <= 390 { return 12 }
        return 13
    }

    private var rowIDs: [String] {
        ["quickSave", "quickLoad", "port0Pad", "port0Mode", "port1Pad", "port1Mode", "quickRemap", "quickFullMenu", "quickRestart", "quickExit"]
    }

    private var quickLoadAvailable: Bool {
        quickLoadSlot != nil
    }

    var body: some View {
        let _ = saveStateRefreshToken
        GeometryReader { geo in
            let cardW = min(340, geo.size.width - 32)
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }

                VStack(alignment: .leading, spacing: 0) {
                    Text(SakuraL10n.tr("emu.quickActions.title"))
                        .font(.system(size: quickMenuBodyFont + 2, weight: .semibold))
                        .foregroundStyle(theme.topBarCaptionColor().opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(rowIDs.enumerated()), id: \.offset) { index, id in
                                    quickMenuRowButton(index: index, rowID: id)
                                        .id(id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 14)
                        }
                        .frame(maxHeight: geo.size.height * 0.7)
                        .onChange(of: focusIndex) { _, idx in
                            guard rowIDs.indices.contains(idx) else { return }
                            withAnimation(theme.emuMenuScrollFocusAnimation) {
                                scrollProxy.scrollTo(rowIDs[idx], anchor: .center)
                            }
                        }
                    }
                }
                .frame(width: cardW, alignment: .leading)
                .modifier(EmuMenuSurface())
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
        .onAppear {
            focusIndex = min(focusIndex, max(0, rowIDs.count - 1))
        }
    }

    @ViewBuilder
    private func quickMenuRowButton(index: Int, rowID: String) -> some View {
        let focused = focusIndex == index
        let pair = labelForRow(rowID)
        let rowDisabled = rowID == "quickLoad" && !quickLoadAvailable

        Button {
            if rowDisabled {
                SFXManager.shared.play(.error)
            } else {
                activateRow(rowID)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(pair.title)
                        .font(.system(size: quickMenuBodyFont, weight: .semibold))
                        .foregroundStyle(
                            rowDisabled
                                ? theme.topBarCaptionColor().opacity(0.45)
                                : theme.topBarTextColor().opacity(0.97)
                        )
                    Spacer()
                    if let val = pair.value {
                        Text(val)
                            .font(.system(size: quickMenuBodyFont - 1))
                            .foregroundStyle(theme.accentColor())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }

                if let sub = pair.subtitle {
                    Text(sub)
                        .font(.system(size: quickMenuBodyFont - 2, weight: .medium))
                        .foregroundStyle(theme.topBarCaptionColor().opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(focused ? theme.accentColor().opacity(0.18) : Color.black.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? theme.accentColor() : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func labelForRow(_ id: String) -> (title: String, subtitle: String?, value: String?) {
        switch id {
        case "quickSave":
            return (SakuraL10n.tr("emu.quickActions.saveState"), nil, nil)
        case "quickLoad":
            return (SakuraL10n.tr("emu.quickActions.loadState"), quickLoadAvailable ? nil : SakuraL10n.tr("emu.quickActions.noQuickSave"), nil)
        case "port0Pad":
            return (SakuraL10n.trf("emu.quickActions.portPad", 1), nil, padLabel(for: 0))
        case "port0Mode":
            return (SakuraL10n.trf("emu.quickActions.portMode", 1), nil, modeLabel(for: 0))
        case "port1Pad":
            return (SakuraL10n.trf("emu.quickActions.portPad", 2), nil, padLabel(for: 1))
        case "port1Mode":
            return (SakuraL10n.trf("emu.quickActions.portMode", 2), nil, modeLabel(for: 1))
        case "quickRemap":
            return (SakuraL10n.tr("emu.quickActions.remap"), SakuraL10n.tr("emu.quickActions.remapSubtitle"), nil)
        case "quickFullMenu":
            return (SakuraL10n.tr("emu.quickActions.menu"), SakuraL10n.tr("emu.quickActions.menuSubtitle"), nil)
        case "quickRestart":
            return (SakuraL10n.tr("emu.quickActions.restart"), SakuraL10n.tr("emu.quickActions.restartSubtitle"), nil)
        case "quickExit":
            return (SakuraL10n.tr("emu.quickActions.exit"), SakuraL10n.tr("emu.quickActions.exitSubtitle"), nil)
        default:
            return ("", nil, nil)
        }
    }

    private func padLabel(for port: Int) -> String {
        if let c = assigner.liveByPort[port] {
            return c.vendorName ?? c.productCategory
        }
        return port == 0 ? SakuraL10n.tr("emu.controllerPopup.touchPad") : SakuraL10n.tr("emu.controllerPopup.empty")
    }

    private func modeLabel(for port: Int) -> String {
        let m = Int(SakuraBridge.ps1ControllerMode(forGame: SakuraBridge.currentISOPath() ?? "", port: Int32(port)))
        return m == 0 ? SakuraL10n.tr("emu.menu.padDigital") : SakuraL10n.tr("emu.menu.padDualShock")
    }

    private func activateRow(_ id: String) {
        SFXManager.shared.play(.confirm)
        switch id {
        case "quickSave": onSave()
        case "quickLoad": onLoad()
        case "port0Pad": cyclePad(for: 0, delta: 1)
        case "port0Mode": cycleMode(for: 0, delta: 1)
        case "port1Pad": cyclePad(for: 1, delta: 1)
        case "port1Mode": cycleMode(for: 1, delta: 1)
        case "quickRemap": onRemap()
        case "quickFullMenu": onMenu()
        case "quickRestart": onRestart()
        case "quickExit": onExit()
        default: break
        }
    }

    private func cyclePad(for port: Int, delta: Int) {
        let pads = assigner.connectedPhysicalControllers()
        let current: Int = {
            guard let live = assigner.liveByPort[port] else { return -1 }
            return pads.firstIndex(where: { $0 === live }) ?? -1
        }()
        let options = [-1] + Array(pads.indices)
        guard let idx = options.firstIndex(of: current) else { return }
        let next = options[((idx + delta) % options.count + options.count) % options.count]
        if next == -1 {
            assigner.clear(port: port)
        } else if pads.indices.contains(next) {
            assigner.reassign(controller: pads[next], to: port)
        }
    }

    private func cycleMode(for port: Int, delta: Int) {
        let cur = Int(SakuraBridge.ps1ControllerMode(forGame: SakuraBridge.currentISOPath() ?? "", port: Int32(port)))
        let next = (cur + delta + 2) % 2
        SakuraBridge.setPS1ControllerModeForCurrentISOOrGlobal(Int32(next), port: Int32(port))
    }
}

enum AutoHideBarOption: String, CaseIterable, Identifiable, Hashable {
    case off, hide, clear
    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .off: return SakuraL10n.tr("ui.autoHideBar.off")
        case .hide: return SakuraL10n.tr("ui.autoHideBar.hide")
        case .clear: return SakuraL10n.tr("ui.autoHideBar.clear")
        }
    }
}

struct InGameSettingsMenuOverlay: View {
    @Bindable private var theme = ThemeManager.shared
    @Bindable private var settings = SettingsStore.shared
    @Bindable private var playtimeMenu = PlaytimeStore.shared
    @ObservedObject private var secondaryDisplay = SecondaryDisplayCoordinator.shared
    @ObservedObject private var inAppScreenRecorder = InAppScreenRecorder.shared
    @ObservedObject private var controllerAssigner = ControllerPortAssigner.shared
    @State private var controllerPads: [GCController] = []

    @Binding var menuExpanded: Bool
    let gameplaySettingsSheetRowIDs: [String]
    @Binding var gameplaySettingsSheetFocusIndex: Int
    @Binding var saveStateRefreshToken: Int
    @Binding var isEditMode: Bool
    @Binding var selectedGroupID: String

    var onDismissBackdrop: () -> Void
    var onBeginEditLayout: () -> Void

    @State private var layout = PadLayoutStore.shared

    private var sakuraHudEnabled: Binding<Bool> {
        Binding(get: { settings.hudEnabled }, set: { settings.hudEnabled = $0 })
    }

    private var ps1BootGameKey: String { SakuraBridge.currentISOPath() ?? "" }

    private var emuMenuAutoHideBinding: Binding<AutoHideBarOption> {
        Binding(
            get: { AutoHideBarOption(rawValue: settings.emuMenuAutoHideBarRaw) ?? .off },
            set: { settings.emuMenuAutoHideBarRaw = $0.rawValue }
        )
    }

    private var neuralUpscaleFramePickerBinding: Binding<String> {
        Binding(
            get: { settings.neuralUpscaleLive ? settings.neuralUpscaleModelToken : NeuralUpscaleRegistry.frameUpscaleOffToken },
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

    private var menuRowBubble: Color {
        theme.inGameMenuBubbleColor().opacity(min(0.48, max(0.04, theme.inGameMenuBubbleFillOpacity)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismissBackdrop)
                sakuraGameMenuPopover(geo: geo)
                    .padding(.top, geo.safeAreaInsets.top + 56)
                    .padding(.leading, max(16, geo.safeAreaInsets.leading + 12))
            }
        }
        .transition(.opacity)
        .onAppear { reloadControllerPads() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadControllerPads() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadControllerPads() }
        .onReceive(NotificationCenter.default.publisher(for: .sakuraControllerPortAssignmentsChanged)) { _ in reloadControllerPads() }
    }

    @ViewBuilder
    private func gameplaySettingsSheetTrackRow(id: String, @ViewBuilder content: () -> some View) -> some View {
        let focused = gameplaySettingsSheetRowIDs.indices.contains(gameplaySettingsSheetFocusIndex)
            && gameplaySettingsSheetRowIDs[gameplaySettingsSheetFocusIndex] == id
        content()
            .id(id)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(focused ? theme.accentColor().opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? theme.accentColor() : Color.clear, lineWidth: 2)
            )
    }

    private func sakuraGameMenuPopover(geo: GeometryProxy) -> some View {
        let leadingPad = max(16, geo.safeAreaInsets.leading + 12)
        let horizontalCap = max(200, geo.size.width - leadingPad - 16)
        let fromLayoutEdge = geo.size.width - leadingPad - 28
        let wish = max(348, fromLayoutEdge)
        let mainWidth = min(min(440, horizontalCap), max(268, wish))
        let menuMaxHeight: CGFloat = max(1, min(500, UIScreen.main.bounds.height * 0.65))
        let menuMinHeight: CGFloat = min(400, menuMaxHeight)
        let bodyFont = Self.menuFontSize(caption: false)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SakuraL10n.tr("emu.menu.title"))
                    .font(.system(size: bodyFont + 2, weight: .semibold))
                    .foregroundStyle(theme.inGameMenuHeaderColor().opacity(0.96))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.general"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "pauseOnMenu") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("emu.menu.pauseInMenu"),
                                    systemImage: "pause.rectangle",
                                    bodyFont: bodyFont,
                                    isOn: $settings.pauseOnMenuEnabled
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "keepSubmenus") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("emu.menu.keepSubmenusOpen"),
                                    systemImage: "list.bullet.indent",
                                    bodyFont: bodyFont,
                                    isOn: $settings.emuMenuKeepSubmenusOpen
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "preventSleep") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("emu.menu.keepScreenOn"),
                                    systemImage: "sun.max.fill",
                                    bodyFont: bodyFont,
                                    isOn: $settings.emuMenuPreventScreenSleep
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "autoHide") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("emu.menu.topBar"), systemImage: "eye.slash", bodyFont: bodyFont) {
                                    Picker("", selection: emuMenuAutoHideBinding) {
                                        ForEach(AutoHideBarOption.allCases) { o in
                                            Text(o.localizedLabel).tag(o)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "confirmStop") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("emu.menu.confirmStop"),
                                    systemImage: "hand.raised.fill",
                                    bodyFont: bodyFont,
                                    isOn: $settings.emuMenuConfirmOnStop
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "inAppScreenRecord") {
                                Button {
                                    inAppScreenRecorder.toggleRecording()
                                } label: {
                                    HStack(alignment: .center, spacing: 8) {
                                        Image(systemName: inAppScreenRecorder.isRecording ? "stop.circle.fill" : "record.circle")
                                            .font(.system(size: max(16, bodyFont + 4)))
                                            .frame(width: 22, alignment: .center)
                                            .foregroundStyle(theme.inGameMenuIconColor())
                                        Text(SakuraL10n.tr("emu.inAppRecord.title"))
                                            .font(.system(size: bodyFont))
                                            .foregroundStyle(theme.inGameMenuTextColor())
                                        Spacer(minLength: 4)
                                        Text(inAppScreenRecorder.isRecording ? SakuraL10n.tr("emu.inAppRecord.actionStop") : SakuraL10n.tr("emu.inAppRecord.actionStart"))
                                            .font(.system(size: bodyFont - 1, weight: .semibold))
                                            .foregroundStyle(theme.accentColor())
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "captureDestination") {
                                gameplaySettingsSheetPickerRow(
                                    title: SakuraL10n.tr("general.capture.saveTo"),
                                    systemImage: "square.and.arrow.down",
                                    bodyFont: bodyFont
                                ) {
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: { SettingsStore.normalizedCaptureDestination(forStored: settings.captureDestination) },
                                            set: { settings.captureDestination = $0 }
                                        )
                                    ) {
                                        ForEach(SettingsStore.localizedCaptureDestinationOptions(), id: \.value) { opt in
                                            Text(opt.label).tag(opt.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "captureHideWhileRecording") {
                                gameplaySettingsSheetPickerRow(
                                    title: SakuraL10n.tr("general.capture.whileRecording"),
                                    systemImage: "eye.slash",
                                    bodyFont: bodyFont
                                ) {
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: { SettingsStore.normalizedCaptureScope(forStored: settings.captureScope) },
                                            set: { settings.captureScope = $0 }
                                        )
                                    ) {
                                        ForEach(SettingsStore.localizedCaptureScopeOptions(), id: \.value) { opt in
                                            Text(opt.label).tag(opt.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "captureTopBarSwap") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("general.capture.topBarSwap"),
                                    systemImage: "camera.on.rectangle",
                                    bodyFont: bodyFont,
                                    isOn: $settings.topBarSwapSpeedForRecord
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "secondaryGameplayPresentation") {
                                gameplaySettingsSheetPickerRow(
                                    title: SakuraL10n.tr("emu.menu.secondaryGameplayPresentation"),
                                    systemImage: "display.2",
                                    bodyFont: bodyFont
                                ) {
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: { secondaryDisplay.mode },
                                            set: { secondaryDisplay.mode = $0 }
                                        )
                                    ) {
                                        Text(SakuraL10n.tr("emu.menu.secondaryGameplay.handheld")).tag(SecondaryGameplayPresentationMode.handheld)
                                        Text(SakuraL10n.tr("emu.menu.secondaryGameplay.tv")).tag(SecondaryGameplayPresentationMode.tv)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.performance"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "perfHostSpeed") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("general.tile.speed"), systemImage: "hare", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.hostEmulationSpeed) {
                                        ForEach(SettingsStore.localizedHostEmulationSpeedOptions(), id: \.value) { opt in
                                            Text(opt.label).tag(opt.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "perfCPU") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("general.tile.cpuFreq"), systemImage: "cpu", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.cpuFreqScale) {
                                        ForEach(SettingsStore.localizedCpuFreqScaleOptions(), id: \.value) { opt in
                                            Text(opt.label).tag(opt.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.audio"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "audioTimeStretch") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("general.tile.timeStretch"),
                                    systemImage: "waveform.path",
                                    bodyFont: bodyFont,
                                    compact: true,
                                    isOn: $settings.audioTimeStretch
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "audioLatency") {
                                gameplaySettingsSheetFloatSliderRow(
                                    title: SakuraL10n.tr("emu.menu.audioLatency"),
                                    systemImage: "waveform",
                                    bodyFont: bodyFont,
                                    value: Binding(
                                        get: { Float(settings.audioLatency) },
                                        set: { settings.audioLatency = Int($0) }
                                    ),
                                    range: 0...512,
                                    step: 8,
                                    caption: { v in SakuraL10n.trf("emu.menu.latencyMsFmt", v) }
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "audioMuteTurbo") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("general.tile.muteTurbo"),
                                    systemImage: "speaker.slash",
                                    bodyFont: bodyFont,
                                    compact: true,
                                    isOn: $settings.muteAudioWhenTurbo
                                )
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.input"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "haptic") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("emu.menu.haptics"),
                                    systemImage: "waveform",
                                    bodyFont: bodyFont,
                                    compact: true,
                                    isOn: Binding(
                                        get: { settings.hapticFeedback },
                                        set: { settings.hapticFeedback = $0 }
                                    )
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "padOpacity") {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "dial.high")
                                            .font(.system(size: max(16, bodyFont + 4)))
                                            .frame(width: 22, alignment: .center)
                                            .foregroundStyle(theme.inGameMenuIconColor())
                                        Text(SakuraL10n.tr("emu.menu.padOpacity"))
                                            .font(.system(size: bodyFont))
                                            .foregroundStyle(theme.inGameMenuTextColor())
                                        Spacer()
                                        Text("\(Int(settings.padOpacity * 100))%")
                                            .font(.system(size: bodyFont - 1))
                                            .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.9))
                                    }
                                    .padding(.horizontal, 8)
                                    Slider(value: Binding(
                                        get: { Double(settings.padOpacity) },
                                        set: { settings.padOpacity = Float($0) }
                                    ), in: 0.1...1.0, step: 0.05)
                                    .tint(theme.accentColor())
                                    .padding(.horizontal, 8)
                                }
                                .padding(.vertical, 8)
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "editLayout") {
                                gameMenuEditLayoutRow(bodyFont: bodyFont)
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "resetLayout") {
                                gameMenuResetLayoutRow(bodyFont: bodyFont)
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.display"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "gfxAspect") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.aspectRatioMenu"), systemImage: "aspectratio", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.aspectRatio) {
                                        Text(SakuraL10n.tr("graphics.aspect.fit")).tag(2)
                                        Text(SakuraL10n.tr("graphics.aspect.fill")).tag(3)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxCropOverscan") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.cropOverscan"), systemImage: "rectangle.compress.vertical", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.cropOverscan) {
                                        ForEach(SettingsStore.localizedCropOverscanOptions(), id: \.value) { opt in
                                            Text(opt.label).tag(opt.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxDeinterlacer") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.ps1Deinterlacer"), systemImage: "line.3.horizontal", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.ps1Deinterlacer) {
                                        ForEach(SettingsStore.localizedPs1DeinterlacerOptions(), id: \.value) { opt in
                                            Text(opt.label).tag(opt.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxResolution") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.internalResolution"), systemImage: "arrow.up.right.and.arrow.down.left.rectangle", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.upscaleMultiplier) {
                                        ForEach(SettingsStore.upscaleMultiplierOptions, id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxNativeDrawable") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.nativeMetalDrawable"),
                                    systemImage: "arrow.up.left.and.arrow.down.right",
                                    bodyFont: bodyFont,
                                    isOn: $settings.nativeScaleMetalDrawable
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxWidescreen") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.widescreenHack"),
                                    systemImage: "rectangle.expand.diagonal",
                                    bodyFont: bodyFont,
                                    isOn: $settings.widescreenHack
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxFrameDuping") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.frameDuping"),
                                    systemImage: "rectangle.on.rectangle",
                                    bodyFont: bodyFont,
                                    isOn: $settings.frameDuping
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxFrameInterp") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.metalFXFrameInterpolation"),
                                    systemImage: "waveform.path.ecg.rectangle",
                                    bodyFont: bodyFont,
                                    isOn: $settings.metalFXFrameInterpolation
                                )
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.enhancements"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "gfxSpatialScaler") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.metalFXTexture"),
                                    systemImage: "checkerboard.rectangle",
                                    bodyFont: bodyFont,
                                    isOn: $settings.metalFXTexture
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxTemporalDisplay") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.metalFXTemporalDisplay"),
                                    systemImage: "film.stack",
                                    bodyFont: bodyFont,
                                    isOn: $settings.metalFXTemporalDisplay
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxNeuralUpscale") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.neuralUpscale"), systemImage: "wand.and.stars", bodyFont: bodyFont) {
                                    Picker("", selection: neuralUpscaleFramePickerBinding) {
                                        ForEach(NeuralUpscaleRegistry.frameUpscaleCycleOptions(), id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxTextureFilter") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.textureFiltering"), systemImage: "camera.filters", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.textureFiltering) {
                                        ForEach(SettingsStore.textureFilteringOptions, id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxFXAA") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.fxaa"),
                                    systemImage: "sparkles",
                                    bodyFont: bodyFont,
                                    isOn: $settings.fxaa
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxSMAA") {
                                gameplaySettingsSheetPickerRow(
                                    title: SakuraL10n.tr("graphics.tile.smaa"),
                                    systemImage: "wand.and.stars",
                                    bodyFont: bodyFont
                                ) {
                                    Picker("", selection: $settings.smaaQuality) {
                                        ForEach(SettingsStore.localizedSmaaQualityOptions(), id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            if settings.smaaQuality > 0 {
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxSMAAPixelArt") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("graphics.tile.smaa.pixelArt"),
                                        systemImage: "square.grid.2x2",
                                        bodyFont: bodyFont,
                                        isOn: $settings.smaaPixelArtMode
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxSMAAAdaptive") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("graphics.tile.smaa.adaptive"),
                                        systemImage: "slider.horizontal.below.square.filled.and.square",
                                        bodyFont: bodyFont,
                                        isOn: $settings.smaaAdaptiveThreshold
                                    )
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxCAS") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.casBrief"),
                                    systemImage: "dial.high",
                                    bodyFont: bodyFont,
                                    isOn: Binding(
                                        get: { settings.casMode != 0 },
                                        set: { settings.casMode = $0 ? 1 : 0 }
                                    )
                                )
                            }
                            if settings.casMode != 0 {
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxCASSharpness") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.casSharpness"),
                                        systemImage: "triangle.fill",
                                        bodyFont: bodyFont,
                                        value: Binding(
                                            get: { Float(settings.casSharpness) },
                                            set: { settings.casSharpness = max(0, min(100, Int($0.rounded()))) }
                                        ),
                                        range: 0...100,
                                        step: 1,
                                        caption: { v in "\(Int(v.rounded()))" }
                                    )
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxPGXP") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.pgxp"), systemImage: "scribble.variable", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.pgxpMode) {
                                        ForEach(SettingsStore.pgxpModeOptions, id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.color"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "gfxColorAdjust") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.colorAdjust"),
                                    systemImage: "paintpalette.fill",
                                    bodyFont: bodyFont,
                                    isOn: $settings.colorAdjustEnabled
                                )
                            }
                            if settings.colorAdjustEnabled {
                                if PresentationColor.extendedBrightnessAvailable {
                                    menuRowDivider()
                                    gameplaySettingsSheetTrackRow(id: "gfxHdrGrade") {
                                        gameplaySettingsSheetToggleRow(
                                            title: SakuraL10n.tr("graphics.tile.hdrEnabled"),
                                            systemImage: "sun.max.circle.fill",
                                            bodyFont: bodyFont,
                                            isOn: $settings.colorAdjustHdrEnabled
                                        )
                                    }
                                    if settings.colorAdjustHdrEnabled {
                                        menuRowDivider()
                                        gameplaySettingsSheetTrackRow(id: "gfxHdrSaturation") {
                                            gameplaySettingsSheetFloatSliderRow(
                                                title: SakuraL10n.tr("graphics.tile.hdrSaturation"),
                                                systemImage: "drop.circle.fill",
                                                bodyFont: bodyFont,
                                                value: $settings.colorAdjustHdrSaturation,
                                                range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                                step: Float(PresentationColor.uniformSliderStep),
                                                caption: { v in String(format: "%.2f", v) }
                                            )
                                        }
                                        menuRowDivider()
                                        gameplaySettingsSheetTrackRow(id: "gfxHdrContrast") {
                                            gameplaySettingsSheetFloatSliderRow(
                                                title: SakuraL10n.tr("graphics.tile.hdrContrast"),
                                                systemImage: "circle.lefthalf.filled.righthalf.striped.horizontal",
                                                bodyFont: bodyFont,
                                                value: $settings.colorAdjustHdrContrast,
                                                range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                                step: Float(PresentationColor.uniformSliderStep),
                                                caption: { v in String(format: "%.2f", v) }
                                            )
                                        }
                                        menuRowDivider()
                                        gameplaySettingsSheetTrackRow(id: "gfxHdrBloom") {
                                            gameplaySettingsSheetFloatSliderRow(
                                                title: SakuraL10n.tr("graphics.tile.hdrBloom"),
                                                systemImage: "sun.haze.fill",
                                                bodyFont: bodyFont,
                                                value: $settings.colorAdjustHdrBloom,
                                                range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                                step: Float(PresentationColor.uniformSliderStep),
                                                caption: { v in String(format: "%.2f", v) }
                                            )
                                        }
                                        menuRowDivider()
                                        gameplaySettingsSheetTrackRow(id: "gfxHdrShadowLift") {
                                            gameplaySettingsSheetFloatSliderRow(
                                                title: SakuraL10n.tr("graphics.tile.hdrShadowLift"),
                                                systemImage: "moon.stars.fill",
                                                bodyFont: bodyFont,
                                                value: $settings.colorAdjustHdrShadowLift,
                                                range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                                step: Float(PresentationColor.uniformSliderStep),
                                                caption: { v in String(format: "%.2f", v) }
                                            )
                                        }
                                        menuRowDivider()
                                        gameplaySettingsSheetTrackRow(id: "gfxHdrHighlightCompress") {
                                            gameplaySettingsSheetFloatSliderRow(
                                                title: SakuraL10n.tr("graphics.tile.hdrHighlightRollOff"),
                                                systemImage: "sun.dust.fill",
                                                bodyFont: bodyFont,
                                                value: $settings.colorAdjustHdrHighlightCompress,
                                                range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                                step: Float(PresentationColor.uniformSliderStep),
                                                caption: { v in String(format: "%.2f", v) }
                                            )
                                        }
                                    }
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorSaturation") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentSaturation"),
                                        systemImage: "drop.circle.fill",
                                        bodyFont: bodyFont,
                                        value: $settings.displayColorSaturation,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorBrightness") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentBrightness"),
                                        systemImage: "sun.min",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustBrightness,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorContrast") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentContrast"),
                                        systemImage: "circle.lefthalf.filled.righthalf.striped.horizontal",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustContrast,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorVibrance") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentVibrance"),
                                        systemImage: "sparkles.square.filled.on.square",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustVibrance,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorExposure") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentExposure"),
                                        systemImage: "camera.aperture",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustExposure,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorGamma") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentGamma"),
                                        systemImage: "chart.bar.doc.horizontal",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustGamma,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorTemperature") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentColorTemp"),
                                        systemImage: "thermometer.medium",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustColorTemperature,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorSharpness") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentSharpness"),
                                        systemImage: "triangle.fill",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustSharpness,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorBloom") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentBloom"),
                                        systemImage: "sun.haze.fill",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustBloom,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorBloomRadius") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentBloomRadius"),
                                        systemImage: "circle.dotted.circle",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustBloomRadius,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorVignette") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentVignette"),
                                        systemImage: "vignette",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustVignette,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "gfxColorVignetteRadius") {
                                    gameplaySettingsSheetFloatSliderRow(
                                        title: SakuraL10n.tr("graphics.tile.presentVignetteRadius"),
                                        systemImage: "circle.circle.right.half.pattern.checkered",
                                        bodyFont: bodyFont,
                                        value: $settings.colorAdjustVignetteRadius,
                                        range: PresentationColor.uniformSliderMin...PresentationColor.uniformSliderMax,
                                        step: Float(PresentationColor.uniformSliderStep),
                                        caption: { v in String(format: "%.2f", v) }
                                    )
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxDither") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.dithering"), systemImage: "circle.grid.3x3", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.ditherMode) {
                                        ForEach(SettingsStore.localizedDitherModeOptions(), id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxColorDepth") {
                                gameplaySettingsSheetPickerRow(title: SakuraL10n.tr("graphics.tile.internalColorDepth"), systemImage: "paintpalette", bodyFont: bodyFont) {
                                    Picker("", selection: $settings.internalColorDepth) {
                                        ForEach(SettingsStore.localizedInternalColorDepthOptions(), id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accentColor())
                                }
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.presentation"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "gfxMainThreadMetalPresent") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("general.tile.mainThreadPresent"),
                                    systemImage: "cpu.fill",
                                    bodyFont: bodyFont,
                                    isOn: $settings.mainThreadMetalPresentEnabled
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxVideotoolbox") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("graphics.tile.videotoolboxShort"),
                                    systemImage: "film",
                                    bodyFont: bodyFont,
                                    isOn: $settings.videotoolboxFrameFeatures
                                )
                            }
                            menuRowDivider()
                            gameplaySettingsSheetTrackRow(id: "gfxReset") {
                                gameMenuResetGraphicsRow(bodyFont: bodyFont)
                            }
                        }
                        menuBubbledSection(title: SakuraL10n.tr("emu.section.hud"), bodyFont: bodyFont) {
                            gameplaySettingsSheetTrackRow(id: "hudEnable") {
                                gameplaySettingsSheetToggleRow(
                                    title: SakuraL10n.tr("osd.tile.hudEnabled"),
                                    systemImage: "gauge.with.dots.needle.67percent",
                                    bodyFont: bodyFont,
                                    isOn: sakuraHudEnabled
                                )
                            }
                            if settings.hudEnabled {
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudFPS") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudFps"),
                                        systemImage: "speedometer",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowFPS },
                                            set: { settings.hudShowFPS = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudSpeed") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudSpeed"),
                                        systemImage: "gauge.medium",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowSpeed },
                                            set: { settings.hudShowSpeed = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudFrame") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudFrameTime"),
                                        systemImage: "waveform.path",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowFrameTime },
                                            set: { settings.hudShowFrameTime = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudCPU") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudCpu"),
                                        systemImage: "cpu",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowCPU },
                                            set: { settings.hudShowCPU = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudRAM") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudRam"),
                                        systemImage: "memorychip",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowRAM },
                                            set: { settings.hudShowRAM = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudGPU") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudGpu"),
                                        systemImage: "square.stack.3d.up",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowGPU },
                                            set: { settings.hudShowGPU = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudRes") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudResolution"),
                                        systemImage: "arrow.up.left.and.arrow.down.right",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowResolution },
                                            set: { settings.hudShowResolution = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudThermal") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudThermal"),
                                        systemImage: "thermometer.medium",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowTemperature },
                                            set: { settings.hudShowTemperature = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudBattery") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudBattery"),
                                        systemImage: "bolt.fill",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowBattery },
                                            set: { settings.hudShowBattery = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudGraphs") {
                                    gameplaySettingsSheetToggleRow(
                                        title: SakuraL10n.tr("osd.tile.hudGraphs"),
                                        systemImage: "chart.xyaxis.line",
                                        bodyFont: bodyFont,
                                        isOn: Binding(
                                            get: { settings.hudShowGraphs },
                                            set: { settings.hudShowGraphs = $0 }
                                        )
                                    )
                                }
                                menuRowDivider()
                                gameplaySettingsSheetTrackRow(id: "hudReset") {
                                    Button {
                                        UserDefaults.standard.removeObject(forKey: "sakura.hud.positionX")
                                        UserDefaults.standard.removeObject(forKey: "sakura.hud.positionY")
                                        UserDefaults.standard.set(0.0, forKey: "sakura.hud.relOffsetX")
                                        UserDefaults.standard.set(0.0, forKey: "sakura.hud.relOffsetY")
                                    } label: {
                                        HStack(alignment: .center, spacing: 8) {
                                            Image(systemName: "arrow.counterclockwise")
                                                .font(.system(size: max(16, bodyFont + 4)))
                                                .frame(width: 22, alignment: .center)
                                                .foregroundStyle(theme.inGameMenuIconColor())
                                            Text(SakuraL10n.tr("emu.menu.resetHudPosition"))
                                                .font(.system(size: bodyFont))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 8)
                                        .foregroundStyle(theme.inGameMenuTextColor().opacity(0.95))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if settings.saveStatesEnabled {
                            menuBubbledSection(title: SakuraL10n.tr("general.section.saveStates"), bodyFont: bodyFont) {
                                ForEach(1...10, id: \.self) { slot in
                                    gameplaySettingsSheetTrackRow(id: "saveSlot_\(slot)") {
                                        saveStateSlotRow(slot: slot, bodyFont: bodyFont)
                                    }
                                    if slot < 10 { menuRowDivider() }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: min(520, UIScreen.main.bounds.height * 0.72))
                .onChange(of: gameplaySettingsSheetFocusIndex) { _, idx in
                    guard gameplaySettingsSheetRowIDs.indices.contains(idx) else { return }
                    withAnimation(theme.emuMenuScrollFocusAnimation) {
                        scrollProxy.scrollTo(gameplaySettingsSheetRowIDs[idx], anchor: .center)
                    }
                }
            }
        }
        .frame(width: mainWidth, alignment: .topLeading)
        .modifier(EmuMenuSurface())
        .frame(minHeight: menuMinHeight, maxHeight: menuMaxHeight)
        .scaleEffect(
            menuExpanded ? 1 : 0.4,
            anchor: .topLeading
        )
        .animation(theme.emuMenuPresentAnimation, value: menuExpanded)
        .onAppear {
            menuExpanded = true
        }
    }

    private func menuRowDivider() -> some View {
        Divider()
            .padding(.leading, 44)
    }

    @ViewBuilder
    private func saveStateSlotRow(slot: Int, bodyFont: CGFloat) -> some View {
        let _ = saveStateRefreshToken
        let exists = SakuraBridge.hasSaveState(inSlot: Int32(slot))
        let date = SakuraBridge.saveStateDate(forSlot: Int32(slot))

        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SakuraL10n.trf("emu.saveState.slotFmt", slot))
                    .font(.system(size: bodyFont, weight: .semibold))
                    .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.95))
                    .lineLimit(1)
                if let d = date {
                    Text(d, style: .relative)
                        .font(.system(size: max(8, bodyFont - 4)))
                        .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.88))
                        .lineLimit(1)
                } else {
                    Text(SakuraL10n.tr("emu.saveState.empty"))
                        .font(.system(size: max(8, bodyFont - 4)))
                        .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(width: 62, alignment: .leading)

            HStack(spacing: 8) {
                saveStateCapsule(
                    title: SakuraL10n.tr("emu.saveState.saveVerb"),
                    systemImage: "arrow.up.doc.fill",
                    font: bodyFont,
                    style: .primary
                ) {
                    if SakuraBridge.saveState(toSlot: Int32(slot)),
                       SettingsStore.shared.mediaScreenshotOnSaveState {
                        InAppScreenRecorder.shared.captureGameplayScreenshotPNG(attachEmbeddedSaveSnapshot: false)
                    }
                    refreshSaveStateRows()
                    HapticManager.firePrimary()
                }

                saveStateCapsule(
                    title: SakuraL10n.tr("emu.saveState.loadVerb"),
                    systemImage: "arrow.down.doc.fill",
                    font: bodyFont,
                    style: exists ? .primary : .disabled
                ) {
                    guard exists else { return }
                    _ = SakuraBridge.loadState(fromSlot: Int32(slot))
                    refreshSaveStateRows()
                    HapticManager.firePrimary()
                }
                .disabled(!exists)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private enum SaveStateCapsuleStyle { case primary, disabled }

    private func refreshSaveStateRows() {
        saveStateRefreshToken &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            saveStateRefreshToken &+= 1
        }
    }

    @ViewBuilder
    private func saveStateCapsule(
        title: String,
        systemImage: String,
        font: CGFloat,
        style: SaveStateCapsuleStyle,
        action: @escaping () -> Void
    ) -> some View {
        let accent = theme.accentColor()
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: max(10, font - 2), weight: .semibold))
                Text(title)
                    .font(.system(size: max(10, font - 2), weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(
                style == .primary
                    ? .white
                    : theme.inGameMenuCaptionColor().opacity(0.6)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(style == .primary ? accent.opacity(0.75) : accent.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(style == .primary ? 0.9 : 0.35), lineWidth: 1)
            )
        }
    }

    private func reloadControllerPads() {
        controllerPads = controllerAssigner.connectedPhysicalControllers()
    }

    @ViewBuilder
    private func gameplaySettingsSheetToggleRow(
        title: String,
        systemImage: String,
        bodyFont: CGFloat,
        compact: Bool = false,
        isOn: Binding<Bool>
    ) -> some View {
        let labelFont = compact ? max(9, bodyFont - 2) : bodyFont
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: max(16, bodyFont + 4)))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(theme.inGameMenuIconColor())
            Text(title)
                .font(.system(size: labelFont))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
                .foregroundStyle(theme.inGameMenuTextColor())
            Spacer(minLength: 4)
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn.wrappedValue },
                    set: { v in
                        isOn.wrappedValue = v
                        SakuraNotificationCenter.shared.postSettingChange(title: title, detail: v ? SakuraL10n.tr("common.on") : SakuraL10n.tr("common.off"))
                    }
                )
            )
                .labelsHidden()
                .controlSize(compact ? .small : .regular)
                .tint(theme.inGameMenuControlAccent())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 4 : 7)
    }

    @ViewBuilder
    private func gameplaySettingsSheetFloatSliderRow(
        title: String,
        systemImage: String,
        bodyFont: CGFloat,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        caption: @escaping (Float) -> String
    ) -> some View {
        VStack(alignment: .center, spacing: 4) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: max(16, bodyFont + 4)))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(theme.inGameMenuIconColor())
                Text(title)
                    .font(.system(size: bodyFont))
                    .foregroundStyle(theme.inGameMenuTextColor())
                Spacer()
                Text(caption(value.wrappedValue))
                    .font(.system(size: bodyFont - 1))
                    .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(theme.accentColor())
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
    }

    private func gameplaySettingsSheetPickerRow<PickerContent: View>(
        title: String,
        systemImage: String,
        bodyFont: CGFloat,
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        let valuePt = max(CGFloat(9), bodyFont - 2)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: max(16, bodyFont + 4)))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(theme.inGameMenuIconColor())
                Text(title)
                    .font(.system(size: bodyFont))
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
                    .foregroundStyle(theme.inGameMenuTextColor())
                Spacer(minLength: 4)
            }
            HStack {
                Spacer(minLength: 0)
                picker()
                    .font(.system(size: valuePt))
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func emuMenuRunningGameBlocks(_ snap: RunningGameSnapshot, bodyFont: CGFloat) -> some View {
        let total = playtimeMenu.totalPlaytime(for: snap.isoFileName)
        let lastPlayed = playtimeMenu.lastPlayed(for: snap.isoFileName)
        let summaryTrim = snap.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 8) {
            Text(snap.displayTitle)
                .font(.system(size: bodyFont + 2, weight: .semibold))
                .foregroundStyle(theme.inGameMenuHeaderColor().opacity(0.98))
                .fixedSize(horizontal: false, vertical: true)

            if !summaryTrim.isEmpty, summaryTrim.caseInsensitiveCompare("unknown") != .orderedSame {
                TranslatedGameMetadataLine(
                    englishRaw: snap.summary,
                    font: .system(size: bodyFont - 1, weight: .regular),
                    lineLimit: 4,
                    minimumScale: 0.78
                )
                .foregroundStyle(theme.inGameMenuTextColor().opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .background(theme.inGameMenuHeaderColor().opacity(0.15))

            emuMenuTranslatedMetaRow(label: SakuraL10n.tr("library.metadata.released"), englishValue: snap.releaseDate, bodyFont: bodyFont)
            emuMenuTranslatedMetaRow(label: SakuraL10n.tr("library.metadata.genre"), englishValue: snap.genre, bodyFont: bodyFont)
            emuMenuTranslatedMetaRow(label: SakuraL10n.tr("library.metadata.developer"), englishValue: snap.developer, bodyFont: bodyFont)
            emuMenuTranslatedMetaRow(label: SakuraL10n.tr("library.metadata.publisher"), englishValue: snap.publisher, bodyFont: bodyFont)

            if total >= 1 {
                emuMenuPlainMetaRow(label: SakuraL10n.tr("library.metadata.playtime"), value: PlaytimeStore.formatDuration(total), bodyFont: bodyFont)
            }
            if let lastPlayed {
                emuMenuPlainMetaRow(label: SakuraL10n.tr("library.metadata.lastPlayed"), value: PlaytimeStore.formatLastPlayed(lastPlayed), bodyFont: bodyFont)
            }
            emuMenuPlainMetaRow(label: SakuraL10n.tr("library.metadata.size"), value: PlaytimeStore.formatByteCount(snap.sizeBytes), bodyFont: bodyFont)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func emuMenuTranslatedMetaRow(label: String, englishValue: String, bodyFont: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: bodyFont - 3, weight: .medium))
                .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            TranslatedGameMetadataLine(
                englishRaw: englishValue,
                font: .system(size: bodyFont, weight: .semibold),
                lineLimit: 2,
                minimumScale: 0.68
            )
            .foregroundStyle(theme.inGameMenuTextColor().opacity(0.98))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emuMenuPlainMetaRow(label: String, value: String, bodyFont: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: bodyFont - 3, weight: .medium))
                .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(value)
                .font(.system(size: bodyFont, weight: .semibold))
                .foregroundStyle(theme.inGameMenuTextColor().opacity(0.98))
                .lineLimit(2)
                .minimumScaleFactor(0.68)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gameMenuSectionHeader(_ title: String, font: CGFloat) -> some View {
        Text(title)
            .font(.system(size: font + 1, weight: .semibold))
            .foregroundStyle(theme.inGameMenuHeaderColor().opacity(0.96))
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    private func menuBubbledSection<Content: View>(title: String, bodyFont: CGFloat, @ViewBuilder content: () -> Content) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                gameMenuSectionHeader(title, font: bodyFont - 1)
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(6)
                .background(menuRowBubble, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        )
    }

    private func gameMenuEditLayoutRow(bodyFont: CGFloat) -> some View {
        Button {
            onBeginEditLayout()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isEditMode ? "checkmark.circle.fill" : "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: max(16, bodyFont + 4)))
                    .foregroundStyle(
                        isEditMode ? theme.inGameMenuControlAccent() : theme.inGameMenuIconColor()
                    )
                    .frame(width: 22, alignment: .center)
                Text(isEditMode ? SakuraL10n.tr("emu.menu.doneEditing") : SakuraL10n.tr("emu.menu.editLayout"))
                    .font(.system(size: bodyFont))
                    .foregroundStyle(
                        isEditMode ? theme.inGameMenuControlAccent() : theme.inGameMenuTextColor().opacity(0.95)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Text(SakuraL10n.tr("emu.menu.dragControlsHint"))
                    .font(.system(size: max(9, bodyFont - 2)))
                    .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func gameMenuResetLayoutRow(bodyFont: CGFloat) -> some View {
        Button {
            layout.reset()
            selectedGroupID = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: max(16, bodyFont + 4)))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(theme.inGameMenuIconColor())
                Text(SakuraL10n.tr("emu.menu.resetPosition"))
                    .font(.system(size: bodyFont))
                    .foregroundStyle(theme.inGameMenuTextColor().opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }


    private func gameMenuResetGraphicsRow(bodyFont: CGFloat) -> some View {
        Button {
            settings.resetGraphicsDefaults()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: max(16, bodyFont + 4)))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(theme.inGameMenuIconColor())
                Text(SakuraL10n.tr("emu.menu.resetGraphics"))
                    .font(.system(size: bodyFont))
                    .foregroundStyle(theme.inGameMenuTextColor().opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private static func menuFontSize(caption: Bool) -> CGFloat {
        let w = UIScreen.main.bounds.width
        if w <= 320 { return caption ? 9 : 10 }
        if w <= 390 { return caption ? 10 : 11 }
        return caption ? 11 : 12
    }

    private func menuFontSize(caption: Bool) -> CGFloat {
        Self.menuFontSize(caption: caption)
    }
}
