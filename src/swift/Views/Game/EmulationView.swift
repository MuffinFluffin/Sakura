// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

private extension Notification.Name {
    static let sakuraPS1ControllerModeChanged = Notification.Name("SakuraPS1ControllerModeChanged")
}

// MARK: - Modifiers

struct HidePersistentOverlaysModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.persistentSystemOverlays(.hidden)
    }
}

// MARK: - Auto-hide bar

private let topBarAutoHideQuietPeriod: TimeInterval = 5.0
private let topBarHiddenButtonsOpacity: Double = 0.04

// MARK: - EmulationView

struct EmulationView: View {
    @State private var appState = AppState.shared
    @Bindable private var settings = SettingsStore.shared
    @ObservedObject private var controllerPorts = ControllerPortAssigner.shared
    @ObservedObject private var screenRecorder = InAppScreenRecorder.shared
    @State private var layout = PadLayoutStore.shared
    @Bindable private var theme = ThemeManager.shared
    @State private var showingEmulationMenu = false
    @State private var showingQuickActions = false
    @State private var quickActionsFocusIndex = 0
    @State private var menuExpanded = false
    @ObservedObject private var secondaryDisplay = SecondaryDisplayCoordinator.shared

    private var quickActionsRowIDs: [String] {
        ["quickSave", "quickLoad", "port0Pad", "port0Mode", "port1Pad", "port1Mode", "quickRemap", "quickFullMenu", "quickRestart", "quickExit"]
    }
    @State private var buttonsOpacity: Double = 1.0
    @State private var lastButtonInteractionTime: Date = Date()
    @State private var showConfirmStop: Bool = false
    @State private var didPauseForMenu: Bool = false
    @State private var saveStateRefreshToken: Int = 0
    @State private var emulationPausedForUI: Bool = false
    @State private var gamepad = GamepadNavigation.shared
    @State private var gameplaySettingsSheetRowIDs: [String] = []
    @State private var gameplaySettingsSheetFocusIndex: Int = 0
    @State private var gameplaySettingsSheetComboLatched: Bool = false
    @State private var topBarPadModeDisplayed: Int = 1
    @State private var controllerPopupShown: Bool = false
    @State private var skipResumeOnNextQuickActionsClose = false
    @State private var emuMenuComboBothSince: Date? = nil
    @State private var emuMenuComboOpenedFullMenuThisGesture = false
    @State private var showingControllerRemapSheet = false
    @State private var isEditMode: Bool = false
    @State private var selectedGroupID: String = ""
    @State private var editorPanelOffset: CGSize = .zero
    @State private var editorPanelBaseOffset: CGSize = .zero
    @State private var showEmuPadExportFail = false
    @State private var emuPadExportFailMessage = ""

    private var resolvedAutoHideBarOption: AutoHideBarOption {
        AutoHideBarOption(rawValue: settings.emuMenuAutoHideBarRaw) ?? .off
    }

    private var gameplaySettingsSheetLayoutToken: Int {
        var h = 0
        h ^= settings.ditherMode.hashValue
        h ^= settings.casMode.hashValue
        h ^= settings.metalFXTexture.hashValue
        h ^= settings.neuralUpscaleLive.hashValue
        h ^= settings.neuralUpscaleModelToken.hashValue
        h ^= settings.metalFXTemporalDisplay.hashValue
        h ^= settings.metalFXFrameInterpolation.hashValue
        h ^= settings.mainThreadMetalPresentEnabled.hashValue
        h ^= settings.videotoolboxFrameFeatures.hashValue
        h ^= settings.pgxpMode.hashValue
        h ^= settings.widescreenHack.hashValue
        h ^= settings.internalColorDepth.hashValue
        h ^= settings.displayColorSaturation.bitPattern.hashValue
        h ^= settings.colorAdjustEnabled.hashValue
        h ^= settings.colorAdjustHdrEnabled.hashValue
        h ^= settings.colorAdjustBrightness.bitPattern.hashValue
        h ^= settings.colorAdjustContrast.bitPattern.hashValue
        h ^= settings.colorAdjustVibrance.bitPattern.hashValue
        h ^= settings.colorAdjustExposure.bitPattern.hashValue
        h ^= settings.colorAdjustGamma.bitPattern.hashValue
        h ^= settings.colorAdjustColorTemperature.bitPattern.hashValue
        h ^= settings.colorAdjustSharpness.bitPattern.hashValue
        h ^= settings.colorAdjustBloom.bitPattern.hashValue
        h ^= settings.colorAdjustBloomRadius.bitPattern.hashValue
        h ^= settings.colorAdjustVignette.bitPattern.hashValue
        h ^= settings.colorAdjustVignetteRadius.bitPattern.hashValue
        h ^= settings.colorAdjustHdrExposure.bitPattern.hashValue
        h ^= settings.colorAdjustHdrSaturation.bitPattern.hashValue
        h ^= settings.colorAdjustHdrContrast.bitPattern.hashValue
        h ^= settings.colorAdjustHdrBloom.bitPattern.hashValue
        h ^= settings.colorAdjustHdrShadowLift.bitPattern.hashValue
        h ^= settings.colorAdjustHdrHighlightCompress.bitPattern.hashValue
        h ^= settings.hudEnabled.hashValue
        h ^= settings.saveStatesEnabled.hashValue
        h ^= settings.emuMenuAutoHideBarRaw.hashValue
        h ^= settings.emuMenuKeepSubmenusOpen.hashValue
        h ^= settings.emuMenuPreventScreenSleep.hashValue
        h ^= settings.emuMenuConfirmOnStop.hashValue
        h ^= settings.audioLatency.hashValue
        h ^= settings.muteAudioWhenTurbo.hashValue
        h ^= settings.audioTimeStretch.hashValue
        h ^= secondaryDisplay.externalRasterSurfaceAvailable.hashValue
        h ^= secondaryDisplay.mainDisplayIsBeingSampled.hashValue
        h ^= secondaryDisplay.gameOnExternalDisplay.hashValue
        h ^= secondaryDisplay.mode.rawValue.hashValue
        h ^= settings.hostEmulationSpeed.bitPattern.hashValue
        h ^= (controllerPorts.liveByPort[0] != nil).hashValue
        return h
    }

    private var padVisible: Bool {
        if isEditMode { return true }
        // Primary rule: a real gamepad on port 1 fully replaces the touch pad.
        // No reason to obscure the screen with virtual buttons the user isn't
        // touching anyway. Applies in both Handheld and TV modes.
        if controllerPorts.liveByPort[0] != nil { return false }
        if screenRecorder.isRecording && settings.recordingHidesVirtualPadWhileCapturing { return false }
        // TV mode: phone is just a touch remote, keep the pad visible so the
        // user has *some* input source on the handheld even when there's no
        // physical controller on port 1.
        return true
    }

    private var hidingTopBarClustersForRecording: Bool {
        screenRecorder.isRecording && settings.recordingHidesTopBarChromeWhileCapturing
    }

    private var phoneChromeDimWhileSampled: Bool {
        secondaryDisplay.mainDisplayIsBeingSampled
            && secondaryDisplay.externalRasterSurfaceAvailable
            && !secondaryDisplay.gameOnExternalDisplay
            && secondaryDisplay.mode == .tv
    }

    private static let pendingLibraryLoadSlotKey = "sakura.library.pendingLoadSlot"
    private static let pendingLibraryLoadISOKey = "sakura.library.pendingLoadISO"

    private func consumePendingLibrarySaveSlotLoadIfNeeded() {
        let d = UserDefaults.standard
        let slot = d.integer(forKey: Self.pendingLibraryLoadSlotKey)
        guard slot >= 1 && slot <= 10 else { return }
        let expectedISO = d.string(forKey: Self.pendingLibraryLoadISOKey) ?? ""
        d.removeObject(forKey: Self.pendingLibraryLoadSlotKey)
        d.removeObject(forKey: Self.pendingLibraryLoadISOKey)
        guard settings.saveStatesEnabled, !expectedISO.isEmpty else { return }
        Task { @MainActor in
            for _ in 0 ..< 80 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard SakuraBridge.isEmulationRunning() else { continue }
                let path = SakuraBridge.currentISOPath() ?? ""
                if path.isEmpty { continue }
                let bootLeaf = (path as NSString).lastPathComponent
                let expectedLeaf = (expectedISO as NSString).lastPathComponent
                let sameGame = path == expectedISO || bootLeaf == expectedLeaf
                guard sameGame else { return }
                guard SakuraBridge.hasSaveState(inSlot: Int32(slot), forISOFileName: expectedISO) else { return }
                _ = SakuraBridge.loadState(fromSlot: Int32(slot))
                saveStateRefreshToken &+= 1
                return
            }
        }
    }

    private static let pendingAttachedSavePathDefaultsKey = PendingMediaAttachedSaveKeys.pathDefaultsKey
    private static let pendingAttachedSaveIsoDefaultsKey = PendingMediaAttachedSaveKeys.expectedISODefaultsKey

    private func consumePendingAttachedSaveFromMediaLibraryIfNeeded() {
        let d = UserDefaults.standard
        guard let statePath = d.string(forKey: Self.pendingAttachedSavePathDefaultsKey), !statePath.isEmpty else {
            return
        }
        let expectedISO = d.string(forKey: Self.pendingAttachedSaveIsoDefaultsKey) ?? ""
        Task { @MainActor in
            for _ in 0 ..< 80 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard SakuraBridge.isEmulationRunning() else { continue }
                let boot = SakuraBridge.currentISOPath() ?? ""
                if boot.isEmpty { continue }
                guard PendingMediaAttachedSaveKeys.isoMatchesStoredBoot(launchingOrBootINI: boot, storedBootPathOrISOFromSidecar: expectedISO) else {
                    continue
                }
                d.removeObject(forKey: Self.pendingAttachedSavePathDefaultsKey)
                d.removeObject(forKey: Self.pendingAttachedSaveIsoDefaultsKey)
                if SakuraBridge.loadSaveStateBytes(fromPath: statePath) {
                    saveStateRefreshToken &+= 1
                } else {
                    SakuraNotificationCenter.shared.postSettingChange(
                        title: SakuraL10n.tr("media.toast.attachedSaveLoadFailed"),
                        detail: nil
                    )
                }
                return
            }
            d.removeObject(forKey: Self.pendingAttachedSavePathDefaultsKey)
            d.removeObject(forKey: Self.pendingAttachedSaveIsoDefaultsKey)
        }
    }

    private var topBarCapsuleBackground: AnyShapeStyle {
        if theme.inGameMenuUsesLiteChrome {
            return AnyShapeStyle(Color.black.opacity(theme.inGameTopBarOpacity))
        }
        if theme.materialsReduced {
            return AnyShapeStyle(Color.black.opacity(min(1, max(theme.inGameTopBarOpacity, 0.78))))
        }
        return AnyShapeStyle(Material.ultraThin)
    }

    private var emulationLayeredContent: some View {
        SakuraPhoneTouchPadShell(
            isEditMode: $isEditMode,
            selectedGroupID: $selectedGroupID,
            padVisible: padVisible
        ) { sw, sh in
            Group {
                if !secondaryDisplay.gameOnExternalDisplay {
                    GameMetalView()
                        .frame(width: sw, height: sh)
                        .opacity(phoneChromeDimWhileSampled ? 0.3 : 1.0)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "airplayvideo")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.55))
                            .symbolRenderingMode(.monochrome)
                        Text(SakuraL10n.tr("emu.gameOnTV"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: sw, height: sh)
                    .background(Color.black)
                }
            }
        }
        .statusBarHidden()
        .modifier(HidePersistentOverlaysModifier())
        .overlay(alignment: .top) {
            floatingTopButtons
                .opacity(buttonsOpacity)
                .animation(theme.emuMenuSmoothAnimation, value: buttonsOpacity)
        }
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 80)
                .contentShape(Rectangle())
                .onTapGesture { restoreButtons() }
                .allowsHitTesting(buttonsOpacity < 1)
        }
        .overlay(alignment: .topTrailing) {
            let showOsd = settings.hudEnabled && !(screenRecorder.isRecording && settings.recordingHidesOsdWhileCapturing)
            if showOsd {
                OSDGameplayOverlay()
                    .opacity(phoneChromeDimWhileSampled ? 0.3 : 1.0)
                    .padding(.top, 10)
                    .padding(.trailing, 12)
            }
        }
        .overlay {
            if showingEmulationMenu {
                gameMenuOverlay
            }
            if showingQuickActions {
                quickActionsOverlay
            }
        }
        .overlay(alignment: .bottom) {
            if isEditMode {
                padEditPanel(maxContainerWidth: UIScreen.main.bounds.width)
            }
        }
    }

    private var emulationWithMenuSettingsObservers: some View {
        emulationLayeredContent
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                emulationPausedForUI = SakuraBridge.isEmulationPaused()
                checkAutoHide()
            }
            .onChange(of: showingEmulationMenu) { _, isOpen in
                emulationPausedForUI = SakuraBridge.isEmulationPaused()
                SakuraBridge.setPhysicalPadToGameSuppressed(isOpen || showingQuickActions || showingControllerRemapSheet)
                if isOpen {
                    gamepad.enterEmulationMenu()
                    rebuildEmuMenuFocusOrder()
                    gameplaySettingsSheetFocusIndex = 0
                } else {
                    if !showingQuickActions {
                        gamepad.leaveEmulationMenu()
                    }
                    menuExpanded = false
                }
            }
            .onChange(of: showingQuickActions) { _, isOpen in
                emulationPausedForUI = SakuraBridge.isEmulationPaused()
                SakuraBridge.setPhysicalPadToGameSuppressed(isOpen || showingEmulationMenu || showingControllerRemapSheet)
                if isOpen {
                    gamepad.enterEmulationMenu()
                    quickActionsFocusIndex = 0
                } else if !showingEmulationMenu {
                    if skipResumeOnNextQuickActionsClose {
                        skipResumeOnNextQuickActionsClose = false
                    } else if didPauseForMenu {
                        SakuraBridge.setEmulationPaused(false)
                        didPauseForMenu = false
                        emulationPausedForUI = SakuraBridge.isEmulationPaused()
                    }
                    gamepad.leaveEmulationMenu()
                }
            }
            .onChange(of: showingControllerRemapSheet) { _, isOpen in
                SakuraBridge.setPhysicalPadToGameSuppressed(isOpen || showingEmulationMenu || showingQuickActions)
                if isOpen {
                    if !SakuraBridge.isEmulationPaused() {
                        SakuraBridge.setEmulationPaused(true)
                        didPauseForMenu = true
                    }
                    emulationPausedForUI = SakuraBridge.isEmulationPaused()
                    gamepad.enterSettings()
                    TileFocus.shared.setPage(
                        sections: PhysicalControllerButtonMappingPanel.focusPageSectionsForStandaloneSheet,
                        columnHint: 3
                    )
                    TileFocus.shared.enterContent()
                } else {
                    gamepad.leave(.settings)
                    gamepad.enterEmulation()
                    if didPauseForMenu {
                        SakuraBridge.setEmulationPaused(false)
                        didPauseForMenu = false
                    }
                    emulationPausedForUI = SakuraBridge.isEmulationPaused()
                }
            }
            .onChange(of: gamepad.actionID) { _, _ in
                if showingEmulationMenu && gamepad.context == .emulationMenu {
                    handleEmuMenuGamepadAction(gamepad.lastAction)
                } else if showingQuickActions && gamepad.context == .emulationMenu {
                    handleQuickActionsGamepadAction(gamepad.lastAction)
                } else if showingControllerRemapSheet && gamepad.context == .settings {
                    handleRemapSheetGamepadAction(gamepad.lastAction)
                }
            }
            .onChange(of: gameplaySettingsSheetLayoutToken) { _, _ in
                if showingEmulationMenu { rebuildEmuMenuFocusOrder() }
            }
            .onReceive(Timer.publish(every: 0.16, on: .main, in: .common).autoconnect()) { _ in
                pollEmuMenuOpenCombo()
            }
            .onChange(of: settings.emuMenuPreventScreenSleep) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            .onChange(of: settings.hudEnabled) { _, on in
                if on {
                    HUDModel.shared.start()
                } else {
                    HUDModel.shared.stop()
                }
            }
            .onChange(of: settings.colorAdjustEnabled) { _, _ in
                if showingEmulationMenu { rebuildEmuMenuFocusOrder() }
            }
            .onChange(of: settings.colorAdjustHdrEnabled) { _, _ in
                if showingEmulationMenu { rebuildEmuMenuFocusOrder() }
            }
            .onChange(of: settings.smaaQuality) { _, _ in
                if showingEmulationMenu { rebuildEmuMenuFocusOrder() }
            }
            .onChange(of: settings.casMode) { _, _ in
                if showingEmulationMenu { rebuildEmuMenuFocusOrder() }
            }
            .onChange(of: settings.pauseOnMenuEnabled) { _, newValue in
                if !newValue, didPauseForMenu, showingEmulationMenu {
                    SakuraBridge.setEmulationPaused(false)
                    didPauseForMenu = false
                }
            }
            .onChange(of: isEditMode) { _, editing in
                if editing {
                    restoreButtons()
                    selectedGroupID = ""
                    editorPanelOffset = .zero
                    editorPanelBaseOffset = .zero
                } else {
                    layout.save()
                }
            }
    }

    private var emulationWithHardwareObservers: some View {
        emulationWithMenuSettingsObservers
            .onReceive(NotificationCenter.default.publisher(for: .sakuraPS1ControllerModeChanged)) { _ in
                syncTopBarDisplayedPadMode()
                if isEditMode {
                    let ids = PadLayoutStore.layoutGroupIDs(forPS1Mode: layout.activeMode)
                    if !selectedGroupID.isEmpty && !ids.contains(selectedGroupID) {
                        selectedGroupID = ""
                    }
                }
            }
            .onChange(of: secondaryDisplay.externalRasterSurfaceAvailable) { _, _ in
                secondaryDisplay.syncExternalDisplayContent()
            }
            .onChange(of: secondaryDisplay.gameOnExternalDisplay) { _, isExternal in
                if !isExternal {
                    RenderHost.shared.nudgeLayout()
                }
                secondaryDisplay.syncExternalDisplayContent()
            }
            .onChange(of: secondaryDisplay.mode) { _, _ in
                secondaryDisplay.syncExternalDisplayContent()
            }
    }

    private var emulationWithSceneLifecycle: some View {
        emulationWithHardwareObservers
            .onAppear {
                syncTopBarDisplayedPadMode()
                gamepad.enterEmulation()
                SakuraBridge.setPhysicalPadToGameSuppressed(false)
                UIApplication.shared.isIdleTimerDisabled = settings.emuMenuPreventScreenSleep
                emulationPausedForUI = SakuraBridge.isEmulationPaused()
                if settings.hudEnabled { HUDModel.shared.start() }
                consumePendingAttachedSaveFromMediaLibraryIfNeeded()
                consumePendingLibrarySaveSlotLoadIfNeeded()
                secondaryDisplay.syncExternalDisplayContent()
            }
            .onDisappear {
                if isEditMode {
                    layout.save()
                }
                gamepad.leaveEmulation()
                SakuraBridge.setPhysicalPadToGameSuppressed(false)
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }

    var body: some View {
        emulationWithSceneLifecycle
            .background {
                ShellKeyboardNavigationHost(
                    shouldClaimFirstResponder: gamepad.hasHardwareKeyboard,
                    gameplaySuppressed: isEditMode || controllerPopupShown
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if controllerPopupShown {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { controllerPopupShown = false }
                        .overlay(alignment: .top) {
                            GeometryReader { geo in
                                HStack {
                                    Spacer(minLength: 0)
                                    ControllerQuickPopupView(isPresented: $controllerPopupShown)
                                        .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
                                    Spacer(minLength: 0)
                                }
                                .padding(.top, geo.safeAreaInsets.top + 56)
                            }
                        }
                        .zIndex(900)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: controllerPopupShown)
            .alert(SakuraL10n.tr("emu.alert.stopTitle"), isPresented: $showConfirmStop) {
                Button(SakuraL10n.tr("common.stop"), role: .destructive) { stopEmulation() }
                Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(SakuraL10n.tr("emu.alert.stopMessage"))
            }
            .alert(SakuraL10n.tr("emu.alert.layoutExportFailTitle"), isPresented: $showEmuPadExportFail) {
                Button(SakuraL10n.tr("common.ok"), role: .cancel) {}
            } message: {
                Text(emuPadExportFailMessage)
            }
            .sheet(isPresented: $showingControllerRemapSheet) {
                NavigationStack {
                    SettingsScroll {
                        PhysicalControllerButtonMappingPanel()
                    }
                    .navigationTitle(SakuraL10n.tr("emu.quickActions.remap"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(SakuraL10n.tr("common.done")) {
                                showingControllerRemapSheet = false
                            }
                        }
                    }
                }
            }
    }

    private func syncTopBarDisplayedPadMode() {
        topBarPadModeDisplayed = Int(SakuraBridge.ps1ControllerMode(forGame: SakuraBridge.currentISOPath() ?? ""))
    }

    private func togglePadModeFromTopBar() {
        recordButtonInteraction()
        HapticManager.fireSecondary()
        let path = SakuraBridge.currentISOPath() ?? ""
        let cur = Int(SakuraBridge.ps1ControllerMode(forGame: path))
        let next = cur == 0 ? 1 : 0
        SakuraBridge.setPS1ControllerModeForCurrentISOOrGlobal(Int32(next))
        topBarPadModeDisplayed = next
    }

    private static let topBarEmuSpeedNormal: Float = 1.0
    private static let topBarEmuSpeedSlow: Float = 0.5
    private static let topBarEmuSpeedFast: Float = 2.0

    private var topBarSlowCpuActive: Bool {
        abs(settings.hostEmulationSpeed - Self.topBarEmuSpeedSlow) < 0.02
    }

    private var topBarFastCpuActive: Bool {
        abs(settings.hostEmulationSpeed - Self.topBarEmuSpeedFast) < 0.02
    }

    private func toggleTopBarSlowCpu() {
        recordButtonInteraction()
        HapticManager.fireSecondary()
        if topBarSlowCpuActive {
            settings.hostEmulationSpeed = Self.topBarEmuSpeedNormal
        } else {
            settings.hostEmulationSpeed = Self.topBarEmuSpeedSlow
        }
    }

    private func toggleTopBarFastCpu() {
        recordButtonInteraction()
        HapticManager.fireSecondary()
        if topBarFastCpuActive {
            settings.hostEmulationSpeed = Self.topBarEmuSpeedNormal
        } else {
            settings.hostEmulationSpeed = Self.topBarEmuSpeedFast
        }
    }

    private func padEditPanel(maxContainerWidth: CGFloat) -> some View {
        let layoutIDs = PadLayoutStore.layoutGroupIDs(forPS1Mode: layout.activeMode)
        let hasSelection = layoutIDs.contains(selectedGroupID)
        let pos = hasSelection ? layout.position(for: selectedGroupID) : PadGroupPosition(x: 0.5, y: 0.5, scale: layout.globalScale)
        let scaleBinding = Binding<Double>(
            get: { Double(hasSelection ? pos.scale : layout.globalScale) },
            set: { updateEditorScale(CGFloat($0), hasSelection: hasSelection) }
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.grid.2x2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.topBarTextColor().opacity(0.9))
                    Text(SakuraL10n.tr("emu.padEdit.headerButtons"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.topBarTextColor())
                    if hasSelection {
                        Text("/")
                            .foregroundStyle(theme.topBarCaptionColor().opacity(0.55))
                        Text(PadLayoutStore.localizedGroupLabel(for: selectedGroupID))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.topBarCaptionColor().opacity(0.95))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            editorPanelOffset = CGSize(
                                width: editorPanelBaseOffset.width + g.translation.width,
                                height: editorPanelBaseOffset.height + g.translation.height
                            )
                        }
                        .onEnded { _ in
                            editorPanelBaseOffset = editorPanelOffset
                        }
                )

                Button {
                    if hasSelection {
                        let defs = PadLayoutStore.defaultPositions(forPS1Mode: layout.activeMode)
                        let def = defs[selectedGroupID]
                            ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
                        layout.positions[selectedGroupID] = def
                    } else {
                        layout.setGlobalScale(1.14)
                    }
                    layout.save()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.topBarTextColor().opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(theme.topBarTextColor().opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    do {
                        try layout.copyExportedLayoutJSONToPasteboard()
                        HapticManager.fireSecondary()
                    } catch {
                        emuPadExportFailMessage = error.localizedDescription
                        showEmuPadExportFail = true
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.topBarTextColor().opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(theme.topBarTextColor().opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SakuraL10n.tr("emu.padEdit.copyExportA11y"))

                Button {
                    layout.save()
                    withAnimation(theme.emuMenuPresentAnimation) {
                        isEditMode = false
                    }
                } label: {
                    Text(SakuraL10n.tr("common.done"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.topBarTextColor())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(theme.topBarControlAccent(), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(hasSelection ? SakuraL10n.tr("emu.padEdit.selectedButton") : SakuraL10n.tr("emu.padEdit.allButtons"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.topBarTextColor().opacity(0.88))
                    Spacer()
                    Text("\(Int(scaleBinding.wrappedValue * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.topBarTextColor())
                }
                Slider(value: scaleBinding, in: 0.5...2.0, step: 0.05)
                    .tint(theme.topBarControlAccent())
            }

            HStack {
                Spacer()
                Text(hasSelection ? SakuraL10n.tr("emu.padEdit.hintSelected") : SakuraL10n.tr("emu.padEdit.hintAll"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.topBarCaptionColor().opacity(0.85))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: min(420, max(280, maxContainerWidth - 40)))
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .offset(editorPanelOffset)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func updateEditorScale(_ scale: CGFloat, hasSelection: Bool) {
        if !hasSelection {
            layout.setGlobalScale(scale)
            return
        }
        updateSelectedGroupScale(scale)
    }

    private func updateSelectedGroupScale(_ scale: CGFloat) {
        let clamped = max(0.5, min(2.0, scale))
        var position = layout.positions[selectedGroupID]
            ?? PadLayoutStore.defaultPositions(forPS1Mode: layout.activeMode)[selectedGroupID]
            ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
        position.scale = clamped
        layout.positions[selectedGroupID] = position
        layout.save()
    }

    private var floatingTopButtons: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Group {
                    if hidingTopBarClustersForRecording && !settings.topBarSwapSpeedForRecord {
                        EmptyView()
                    } else {
                        primaryTopBarCapsuleClusters
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, geo.safeAreaInsets.top + 8)
                .allowsHitTesting(buttonsOpacity == 1)

                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var primaryTopBarCapsuleClusters: some View {
        let hideSidesForCapture = hidingTopBarClustersForRecording && settings.topBarSwapSpeedForRecord
        return ZStack {
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        recordButtonInteraction()
                        openGameMenu()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .foregroundStyle(theme.topBarTextColor())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 40, height: 40)
                    .accessibilityLabel(SakuraL10n.tr("emu.topBar.gameMenuA11y"))
                    .accessibilityHint(SakuraL10n.tr("emu.topBar.gameMenuHintA11y"))

                    if settings.saveStatesEnabled {
                        Button {
                            recordButtonInteraction()
                            quickSaveState()
                        } label: {
                            Image(systemName: "arrow.up.doc.fill")
                                .font(.title2)
                                .foregroundStyle(theme.topBarTextColor())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 40, height: 40)
                        .accessibilityLabel(SakuraL10n.tr("emu.topBar.quickSaveA11y"))
                        .accessibilityHint(SakuraL10n.tr("emu.topBar.quickSaveHintA11y"))
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                                recordButtonInteraction()
                                quickLoadState()
                            }
                        )

                        Button {
                            recordButtonInteraction()
                            quickLoadState()
                        } label: {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title2)
                                .foregroundStyle(
                                    quickLoadSlot == nil
                                        ? theme.topBarCaptionColor().opacity(0.5)
                                        : theme.topBarTextColor()
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 40, height: 40)
                        .accessibilityLabel(SakuraL10n.tr("emu.topBar.quickLoadA11y"))
                        .accessibilityValue(
                            quickLoadSlot.map { SakuraL10n.trf("emu.saveState.slotFmt", $0) }
                                ?? SakuraL10n.tr("emu.topBar.quickLoadValueEmpty")
                        )
                        .accessibilityHint(SakuraL10n.tr("emu.topBar.quickLoadHintA11y"))
                        .disabled(quickLoadSlot == nil)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(topBarCapsuleBackground, in: Capsule())
                .opacity(hideSidesForCapture ? 0 : 1)
                .allowsHitTesting(!hideSidesForCapture)

                Spacer(minLength: 6)

                Group {
                    if settings.topBarSwapSpeedForRecord {
                        topBarScreenshotAndRecordAccessoryStrip
                    } else {
                        topBarCpuSpeedAccessoryStrip
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(topBarCapsuleBackground, in: Capsule())

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Button {
                        recordButtonInteraction()
                        SakuraBridge.setEmulationPaused(!SakuraBridge.isEmulationPaused())
                        emulationPausedForUI = SakuraBridge.isEmulationPaused()
                    } label: {
                        Image(systemName: emulationPausedForUI ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .foregroundStyle(theme.topBarTextColor())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 40, height: 40)
                    .accessibilityLabel(
                        emulationPausedForUI
                            ? SakuraL10n.tr("emu.topBar.pauseResumeA11y") : SakuraL10n.tr("emu.topBar.pausePauseA11y")
                    )
                    .accessibilityHint(SakuraL10n.tr("emu.topBar.pauseHintA11y"))

                    Button {
                        recordButtonInteraction()
                        reloadGame()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title2)
                            .foregroundStyle(theme.topBarTextColor())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 40, height: 40)
                    .accessibilityLabel(SakuraL10n.tr("emu.topBar.restartA11y"))
                    .accessibilityHint(SakuraL10n.tr("emu.topBar.restartHintA11y"))

                    Button {
                        recordButtonInteraction()
                        if settings.emuMenuConfirmOnStop {
                            showConfirmStop = true
                        } else {
                            stopEmulation()
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                            .foregroundStyle(theme.topBarTextColor())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 40, height: 40)
                    .accessibilityLabel(SakuraL10n.tr("emu.topBar.stopA11y"))
                    .accessibilityHint(
                        settings.emuMenuConfirmOnStop
                            ? SakuraL10n.tr("emu.topBar.stopHintConfirmA11y")
                            : SakuraL10n.tr("emu.topBar.stopHintDirectA11y")
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(topBarCapsuleBackground, in: Capsule())
                .opacity(hideSidesForCapture ? 0 : 1)
                .allowsHitTesting(!hideSidesForCapture)
            }
        }
    }

    private var topBarCpuSpeedAccessoryStrip: some View {
        HStack(spacing: 2) {
            Button {
                toggleTopBarSlowCpu()
            } label: {
                Image(systemName: "tortoise.fill")
                    .font(.title3)
                    .foregroundStyle(
                        topBarSlowCpuActive ? theme.topBarControlAccent().opacity(0.95) : theme.topBarTextColor()
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .accessibilityLabel(SakuraL10n.tr("emu.topBar.slowCpuA11y"))
            .accessibilityHint(SakuraL10n.tr("emu.topBar.slowCpuHintA11y"))
            .accessibilityAddTraits(topBarSlowCpuActive ? [.isSelected] : [])

            Button {
                recordButtonInteraction()
                controllerPopupShown.toggle()
            } label: {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(topBarPadModeDisplayed == 0 ? theme.topBarTextColor() : theme.topBarControlAccent().opacity(0.95))
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in togglePadModeFromTopBar() })
            .accessibilityLabel(SakuraL10n.tr("emu.topBar.controllerModeA11y"))
            .accessibilityHint(SakuraL10n.tr("emu.topBar.controllerModeHintA11y"))
            .accessibilityValue(
                topBarPadModeDisplayed == 0
                    ? SakuraL10n.tr("emu.menu.padDigital") : SakuraL10n.tr("emu.menu.padDualShock")
            )

            Button {
                toggleTopBarFastCpu()
            } label: {
                Image(systemName: "hare.fill")
                    .font(.title3)
                    .foregroundStyle(
                        topBarFastCpuActive ? theme.topBarControlAccent().opacity(0.95) : theme.topBarTextColor()
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .accessibilityLabel(SakuraL10n.tr("emu.topBar.fastCpuA11y"))
            .accessibilityHint(SakuraL10n.tr("emu.topBar.fastCpuHintA11y"))
            .accessibilityAddTraits(topBarFastCpuActive ? [.isSelected] : [])
        }
    }

    private var topBarScreenshotAndRecordAccessoryStrip: some View {
        HStack(spacing: 2) {
            Button {
                recordButtonInteraction()
                screenRecorder.captureGameplayScreenshotPNG()
            } label: {
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(theme.topBarTextColor())
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .accessibilityLabel(SakuraL10n.tr("emu.topBar.screenshotA11y"))
            .accessibilityHint(SakuraL10n.tr("emu.topBar.screenshotHintA11y"))

            Button {
                recordButtonInteraction()
                controllerPopupShown.toggle()
            } label: {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(topBarPadModeDisplayed == 0 ? theme.topBarTextColor() : theme.topBarControlAccent().opacity(0.95))
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in togglePadModeFromTopBar() })
            .accessibilityLabel(SakuraL10n.tr("emu.topBar.controllerModeA11y"))
            .accessibilityHint(SakuraL10n.tr("emu.topBar.controllerModeHintA11y"))
            .accessibilityValue(
                topBarPadModeDisplayed == 0
                    ? SakuraL10n.tr("emu.menu.padDigital") : SakuraL10n.tr("emu.menu.padDualShock")
            )

            Button {
                recordButtonInteraction()
                screenRecorder.toggleRecording()
            } label: {
                Image(systemName: screenRecorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title3)
                    .foregroundStyle(screenRecorder.isRecording ? Color.red.opacity(0.95) : theme.topBarTextColor())
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .accessibilityLabel(SakuraL10n.tr("emu.topBar.recordA11y"))
            .accessibilityHint(SakuraL10n.tr("emu.topBar.recordHintA11y"))
            .accessibilityAddTraits(screenRecorder.isRecording ? [.isSelected] : [])
        }
    }

    private var gameMenuOverlay: some View {
        InGameSettingsMenuOverlay(
            menuExpanded: $menuExpanded,
            gameplaySettingsSheetRowIDs: gameplaySettingsSheetRowIDs,
            gameplaySettingsSheetFocusIndex: $gameplaySettingsSheetFocusIndex,
            saveStateRefreshToken: $saveStateRefreshToken,
            isEditMode: $isEditMode,
            selectedGroupID: $selectedGroupID,
            onDismissBackdrop: dismissGameMenu,
            onBeginEditLayout: {
                dismissGameMenu()
                layout.syncLayoutPresetFromBridge()
                withAnimation(theme.layoutEditSpringAnimation) { isEditMode = true }
            }
        )
    }

    private var quickActionsOverlay: some View {
        InGameQuickActionsOverlay(
            isPresented: $showingQuickActions,
            focusIndex: $quickActionsFocusIndex,
            saveStateRefreshToken: $saveStateRefreshToken,
            quickLoadSlot: quickLoadSlot,
            onSave: { quickSaveState() },
            onLoad: { quickLoadState() },
            onRemap: {
                skipResumeOnNextQuickActionsClose = true
                dismissQuickActions()
                showingControllerRemapSheet = true
            },
            onMenu: {
                showingQuickActions = false
                openGameMenu()
            },
            onRestart: {
                showingQuickActions = false
                reloadGame()
            },
            onExit: {
                showingQuickActions = false
                stopEmulation()
            }
        )
    }

    private func refreshSaveStateRows() {
        saveStateRefreshToken &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            saveStateRefreshToken &+= 1
        }
    }


    private func recordButtonInteraction() {
        lastButtonInteractionTime = Date()
        if buttonsOpacity < 1 { restoreButtons() }
    }

    private func checkAutoHide() {
        guard resolvedAutoHideBarOption != .off else { return }
        guard !showingEmulationMenu else { return }
        guard buttonsOpacity >= 1 else { return }
        guard Date().timeIntervalSince(lastButtonInteractionTime) >= topBarAutoHideQuietPeriod else { return }
        withAnimation(theme.emuMenuSmoothAnimation) {
            switch resolvedAutoHideBarOption {
            case .off: break
            case .hide: buttonsOpacity = 0
            case .clear: buttonsOpacity = topBarHiddenButtonsOpacity
            }
        }
    }

    private func restoreButtons() {
        lastButtonInteractionTime = Date()
        withAnimation(theme.emuMenuSmoothAnimation) {
            buttonsOpacity = 1
        }
    }

    private func emulationMenuCasRows() -> [String] {
        settings.casMode != 0 ? ["gfxCASSharpness"] : []
    }

    private func emulationMenuSmaaRows() -> [String] {
        settings.smaaQuality > 0 ? ["gfxSMAAPixelArt", "gfxSMAAAdaptive"] : []
    }

    private func emulationMenuGraphicsColorRows() -> [String] {
        var rows: [String] = []
        if settings.colorAdjustEnabled {
            if PresentationColor.extendedBrightnessAvailable {
                rows.append("gfxHdrGrade")
                if settings.colorAdjustHdrEnabled {
                    rows.append(contentsOf: [
                        "gfxHdrSaturation", "gfxHdrContrast", "gfxHdrBloom",
                        "gfxHdrShadowLift", "gfxHdrHighlightCompress",
                    ])
                }
            }
            rows.append(contentsOf: [
                "gfxColorSaturation", "gfxColorBrightness", "gfxColorContrast", "gfxColorVibrance",
                "gfxColorExposure", "gfxColorGamma", "gfxColorTemperature", "gfxColorSharpness",
                "gfxColorBloom", "gfxColorBloomRadius", "gfxColorVignette", "gfxColorVignetteRadius",
            ])
        }
        return rows
    }

    private func rebuildEmuMenuFocusOrder() {
        var ids: [String] = [
            "pauseOnMenu", "keepSubmenus", "preventSleep", "autoHide", "confirmStop",
            "inAppScreenRecord",
            "captureDestination",
            "captureHideWhileRecording",
            "captureTopBarSwap",
            "secondaryGameplayPresentation",
        ]
        ids.append(contentsOf: [
            "perfHostSpeed", "perfCPU",
            "audioTimeStretch", "audioLatency", "audioMuteTurbo",
            "haptic", "padOpacity", "editLayout", "resetLayout",
            "gfxAspect", "gfxCropOverscan", "gfxDeinterlacer", "gfxResolution", "gfxNativeDrawable", "gfxWidescreen", "gfxFrameDuping", "gfxFrameInterp",
            "gfxSpatialScaler", "gfxTemporalDisplay", "gfxNeuralUpscale",
            "gfxTextureFilter", "gfxFXAA", "gfxSMAA",
        ])
        ids.append(contentsOf: emulationMenuSmaaRows())
        ids.append("gfxCAS")
        ids.append(contentsOf: emulationMenuCasRows())
        ids.append(contentsOf: [
            "gfxPGXP",
            "gfxColorAdjust",
        ])
        ids.append(contentsOf: emulationMenuGraphicsColorRows())
        ids.append(contentsOf: [
            "gfxDither", "gfxColorDepth",
            "gfxMainThreadMetalPresent", "gfxVideotoolbox",
            "gfxReset",
        ])
        ids += ["hudEnable"]
        if settings.hudEnabled {
            ids += [
                "hudFPS", "hudSpeed", "hudFrame", "hudCPU", "hudRAM", "hudGPU", "hudRes",
                "hudThermal", "hudBattery", "hudGraphs", "hudReset",
            ]
        }
        if settings.saveStatesEnabled {
            for s in 1...10 { ids.append("saveSlot_\(s)") }
        }
        gameplaySettingsSheetRowIDs = ids
        if gameplaySettingsSheetFocusIndex >= ids.count {
            gameplaySettingsSheetFocusIndex = max(0, ids.count - 1)
        }
    }

    private func pollEmuMenuOpenCombo() {
        guard !showingEmulationMenu, !isEditMode else { return }
        guard let pair = EmuMenuComboStorage.resolvedPair() else { return }
        let a = SakuraBridge.isSDLGamepadButtonPressed(Int32(pair.0))
        let b = SakuraBridge.isSDLGamepadButtonPressed(Int32(pair.1))
        let both = a && b
        if showingControllerRemapSheet {
            if both {
                if emuMenuComboBothSince == nil { emuMenuComboBothSince = Date() }
            } else {
                if emuMenuComboBothSince != nil {
                    showingControllerRemapSheet = false
                    SFXManager.shared.play(.back)
                }
                emuMenuComboBothSince = nil
                emuMenuComboOpenedFullMenuThisGesture = false
                gameplaySettingsSheetComboLatched = false
            }
            return
        }
        if showingQuickActions { return }
        guard gamepad.context == .emulation else { return }
        if both {
            if emuMenuComboBothSince == nil {
                emuMenuComboBothSince = Date()
            }
            if let t = emuMenuComboBothSince,
               !emuMenuComboOpenedFullMenuThisGesture,
               Date().timeIntervalSince(t) >= 0.45 {
                emuMenuComboOpenedFullMenuThisGesture = true
                gameplaySettingsSheetComboLatched = true
                openGameMenu()
            }
        } else {
            if let t = emuMenuComboBothSince {
                let elapsed = Date().timeIntervalSince(t)
                if !emuMenuComboOpenedFullMenuThisGesture, elapsed < 0.45 {
                    openQuickActions()
                }
            }
            emuMenuComboBothSince = nil
            emuMenuComboOpenedFullMenuThisGesture = false
            gameplaySettingsSheetComboLatched = false
        }
    }

    private func handleRemapSheetGamepadAction(_ action: GamepadAction?) {
        guard let action else { return }
        let focus = TileFocus.shared
        if focus.isCapturing {
            if action == .captureCancel || action == .back {
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
            focus.move(-1)
        case .moveRight:
            focus.move(1)
        case .moveUp:
            focus.moveRow(-1)
        case .moveDown:
            focus.moveRow(1)
        case .confirm:
            focus.confirm()
        case .back, .menu:
            SFXManager.shared.play(.back)
            showingControllerRemapSheet = false
        default:
            break
        }
    }

    private func openQuickActions() {
        guard !isEditMode else { return }
        if settings.saveStatesEnabled {
            refreshSaveStateRows()
        }
        if !SakuraBridge.isEmulationPaused() {
            SakuraBridge.setEmulationPaused(true)
            didPauseForMenu = true
        }
        emulationPausedForUI = SakuraBridge.isEmulationPaused()
        quickActionsFocusIndex = 0
        withAnimation(theme.emuMenuPresentAnimation) {
            showingQuickActions = true
        }
    }

    private func handleQuickActionsGamepadAction(_ action: GamepadAction?) {
        guard let action else { return }
        let ids = quickActionsRowIDs
        guard !ids.isEmpty else { return }
        let row = ids[quickActionsFocusIndex]
        
        switch action {
        case .back, .menu:
            SFXManager.shared.play(.back)
            dismissQuickActions()
        case .moveUp:
            SFXManager.shared.play(.navigate)
            quickActionsFocusIndex = (quickActionsFocusIndex - 1 + ids.count) % ids.count
        case .moveDown:
            SFXManager.shared.play(.navigate)
            quickActionsFocusIndex = (quickActionsFocusIndex + 1) % ids.count
        case .moveLeft, .shoulderLeft:
            if quickActionsRowIsPicker(row) {
                SFXManager.shared.play(.navigate)
                nudgeQuickActionsField(row: row, delta: -1)
            }
        case .moveRight, .shoulderRight:
            if quickActionsRowIsPicker(row) {
                SFXManager.shared.play(.navigate)
                nudgeQuickActionsField(row: row, delta: 1)
            }
        case .confirm:
            SFXManager.shared.play(.confirm)
            activateQuickActionsRow(row)
        case .secondary:
            if quickActionsRowIsPicker(row) {
                SFXManager.shared.play(.navigate)
                nudgeQuickActionsField(row: row, delta: -1)
            }
        case .tertiary, .triggerLeft, .triggerRight, .captureCancel:
            break
        }
    }

    private func quickActionsRowIsPicker(_ row: String) -> Bool {
        return row.hasPrefix("port")
    }

    private func nudgeQuickActionsField(row: String, delta: Int) {
        switch row {
        case "port0Pad": cyclePS1PortAssignment(port: 0, delta: delta)
        case "port0Mode": cyclePS1PortMode(port: 0, delta: delta)
        case "port1Pad": cyclePS1PortAssignment(port: 1, delta: delta)
        case "port1Mode": cyclePS1PortMode(port: 1, delta: delta)
        default: break
        }
    }

    private func activateQuickActionsRow(_ row: String) {
        switch row {
        case "quickSave":
            quickSaveState()
            dismissQuickActions()
        case "quickLoad":
            if quickLoadSlot != nil {
                quickLoadState()
                dismissQuickActions()
            } else {
                SFXManager.shared.play(.error)
            }
        case "port0Pad": cyclePS1PortAssignment(port: 0, delta: 1)
        case "port0Mode": cyclePS1PortMode(port: 0, delta: 1)
        case "port1Pad": cyclePS1PortAssignment(port: 1, delta: 1)
        case "port1Mode": cyclePS1PortMode(port: 1, delta: 1)
        case "quickRemap":
            skipResumeOnNextQuickActionsClose = true
            dismissQuickActions()
            showingControllerRemapSheet = true
        case "quickFullMenu":
            dismissQuickActions()
            openGameMenu()
        case "quickRestart":
            dismissQuickActions()
            reloadGame()
        case "quickExit":
            dismissQuickActions()
            stopEmulation()
        default: break
        }
    }

    private func dismissQuickActions() {
        guard showingQuickActions else { return }
        if !skipResumeOnNextQuickActionsClose, didPauseForMenu {
            SakuraBridge.setEmulationPaused(false)
            didPauseForMenu = false
        }
        emulationPausedForUI = SakuraBridge.isEmulationPaused()
        withAnimation(theme.emuMenuPresentAnimation) {
            showingQuickActions = false
        }
    }

    private func handleEmuMenuGamepadAction(_ action: GamepadAction?) {
        guard let action else { return }
        guard !gameplaySettingsSheetRowIDs.isEmpty else { return }
        let row = gameplaySettingsSheetRowIDs[gameplaySettingsSheetFocusIndex]
        switch action {
        case .back, .menu:
            SFXManager.shared.play(.back)
            dismissGameMenu()
        case .moveUp:
            SFXManager.shared.play(.navigate)
            gameplaySettingsSheetFocusIndex = (gameplaySettingsSheetFocusIndex - 1 + gameplaySettingsSheetRowIDs.count) % gameplaySettingsSheetRowIDs.count
        case .moveDown:
            SFXManager.shared.play(.navigate)
            gameplaySettingsSheetFocusIndex = (gameplaySettingsSheetFocusIndex + 1) % gameplaySettingsSheetRowIDs.count
        case .moveLeft, .shoulderLeft:
            if gameplaySettingsSheetRowIsPicker(row) || gameplaySettingsSheetRowIsSlider(row) {
                SFXManager.shared.play(.navigate)
                nudgeEmuMenuField(row: row, delta: -1)
                notifyEmuMenuSettingNotification(for: row)
            }
        case .moveRight, .shoulderRight:
            if gameplaySettingsSheetRowIsPicker(row) || gameplaySettingsSheetRowIsSlider(row) {
                SFXManager.shared.play(.navigate)
                nudgeEmuMenuField(row: row, delta: 1)
                notifyEmuMenuSettingNotification(for: row)
            }
        case .confirm:
            SFXManager.shared.play(.confirm)
            activateEmuMenuRow(row)
        case .secondary:
            SFXManager.shared.play(.toggle)
            secondaryEmuMenuRow(row)
        case .tertiary, .triggerLeft, .triggerRight, .captureCancel:
            break
        }
    }

    private func gameplaySettingsSheetRowIsSlider(_ row: String) -> Bool {
        switch row {
        case "padOpacity", "audioLatency", "gfxColorSaturation", "gfxColorBrightness", "gfxColorContrast", "gfxColorVibrance",
            "gfxColorExposure", "gfxColorGamma", "gfxColorTemperature", "gfxColorSharpness",
            "gfxColorBloom", "gfxColorBloomRadius", "gfxColorVignette", "gfxColorVignetteRadius",
            "gfxHdrExposure", "gfxHdrSaturation", "gfxHdrContrast", "gfxHdrBloom",
            "gfxHdrShadowLift", "gfxHdrHighlightCompress", "gfxCASSharpness":
            return true
        default:
            return false
        }
    }

    private func gameplaySettingsSheetRowIsPicker(_ row: String) -> Bool {
        switch row {
        case "autoHide", "secondaryGameplayPresentation", "perfHostSpeed", "perfCPU",
            "gfxAspect", "gfxCropOverscan", "gfxDeinterlacer",
            "gfxResolution", "gfxTextureFilter", "gfxNeuralUpscale", "gfxDither",
            "gfxPGXP", "gfxColorDepth", "captureHideWhileRecording", "captureDestination":
            return true
        default:
            return false
        }
    }

    private func bump(_ slot: ReferenceWritableKeyPath<SettingsStore, Float>, lo: Float, hi: Float, delta: Int, step: Float) {
        let cur = settings[keyPath: slot]
        let nv = Float(min(Double(hi), max(Double(lo), Double(cur) + Double(delta) * Double(step))))
        settings[keyPath: slot] = nv
    }

    private func nudgeEmuMenuField(row: String, delta: Int) {
        switch row {
        case "padOpacity":
            let v = max(0.1, min(1.0, Double(settings.padOpacity) + Double(delta) * 0.05))
            settings.padOpacity = Float(v)
        case "autoHide":
            cycleAutoHide(delta)
        case "secondaryGameplayPresentation":
            let order: [SecondaryGameplayPresentationMode] = [.handheld, .tv]
            if let i = order.firstIndex(of: secondaryDisplay.mode) {
                let n = order.count
                secondaryDisplay.mode = order[((i + delta) % n + n) % n]
            }
        case "perfHostSpeed":
            cycleHostEmulationSpeed(delta)
        case "audioLatency":
            let cur = settings.audioLatency
            let nv = max(0, min(512, cur + delta * 8))
            settings.audioLatency = nv
        case "perfCPU":
            cycleCpuFreqScale(delta)
        case "gfxAspect":
            cycleAspect(delta)
        case "gfxCropOverscan":
            cycleCropOverscan(delta)
        case "gfxDeinterlacer":
            cycleDeinterlacer(delta)
        case "gfxResolution":
            cycleUpscale(delta)
        case "gfxTextureFilter":
            settings.textureFiltering = cycleIntWrappingInRange(settings.textureFiltering, 0...7, delta)
        case "gfxNeuralUpscale":
            cycleNeuralFrame(delta)
        case "gfxDither":
            cycleDither(delta)
        case "gfxPGXP":
            cyclePGXP(delta)
        case "gfxColorSaturation":
            bump(\.displayColorSaturation, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorBrightness":
            bump(\.colorAdjustBrightness, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorContrast":
            bump(\.colorAdjustContrast, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorVibrance":
            bump(\.colorAdjustVibrance, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorExposure":
            bump(\.colorAdjustExposure, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorGamma":
            bump(\.colorAdjustGamma, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorTemperature":
            bump(\.colorAdjustColorTemperature, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorSharpness":
            bump(\.colorAdjustSharpness, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxCASSharpness":
            let cur = settings.casSharpness
            settings.casSharpness = max(0, min(100, cur + delta))
        case "gfxColorBloom":
            bump(\.colorAdjustBloom, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorBloomRadius":
            bump(\.colorAdjustBloomRadius, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorVignette":
            bump(\.colorAdjustVignette, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorVignetteRadius":
            bump(\.colorAdjustVignetteRadius, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxHdrExposure":
            bump(\.colorAdjustHdrExposure, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxHdrSaturation":
            bump(\.colorAdjustHdrSaturation, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxHdrContrast":
            bump(\.colorAdjustHdrContrast, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxHdrBloom":
            bump(\.colorAdjustHdrBloom, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxHdrShadowLift":
            bump(\.colorAdjustHdrShadowLift, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxHdrHighlightCompress":
            bump(\.colorAdjustHdrHighlightCompress, lo: PresentationColor.uniformSliderMin, hi: PresentationColor.uniformSliderMax, delta: delta, step: Float(PresentationColor.uniformSliderStep))
        case "gfxColorDepth":
            cycleColorDepth(delta)
        case "captureHideWhileRecording":
            cycleCaptureScope(delta)
        case "captureDestination":
            cycleCaptureDestination(delta)
        default:
            break
        }
    }

    private func cycleIntWrappingInRange(_ v: Int, _ r: ClosedRange<Int>, _ delta: Int) -> Int {
        let opts = Array(r)
        guard let i = opts.firstIndex(of: v) else { return opts[0] }
        let n = opts.count
        let j = ((i + delta) % n + n) % n
        return opts[j]
    }

    private func cyclePS1PortMode(port: Int, delta: Int) {
        guard port == 0 || port == 1 else { return }
        let cur = Int(SakuraBridge.ps1ControllerMode(forGame: ps1BootGameKey, port: Int32(port)))
        let next = (cur + delta + 2) % 2
        SakuraBridge.setPS1ControllerModeForCurrentISOOrGlobal(Int32(next), port: Int32(port))
    }

    private func cyclePS1PortAssignment(port: Int, delta: Int) {
        guard port == 0 || port == 1 else { return }
        let assigner = ControllerPortAssigner.shared
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

    private func ps1PortAssignmentLabel(port: Int) -> String {
        let assigner = ControllerPortAssigner.shared
        if assigner.liveByPort.indices.contains(port), let c = assigner.liveByPort[port] {
            return c.vendorName ?? c.productCategory
        }
        return port == 0 ? SakuraL10n.tr("emu.controllerPopup.touchPad") : SakuraL10n.tr("emu.controllerPopup.empty")
    }

    private func cycleCaptureScope(_ delta: Int) {
        let opts = SettingsStore.localizedCaptureScopeOptions().map(\.value)
        let cur = SettingsStore.normalizedCaptureScope(forStored: settings.captureScope)
        guard let i = opts.firstIndex(of: cur) else {
            settings.captureScope = opts[0]
            return
        }
        let n = opts.count
        settings.captureScope = opts[((i + delta) % n + n) % n]
    }

    private func cycleCaptureDestination(_ delta: Int) {
        let opts = SettingsStore.localizedCaptureDestinationOptions().map(\.value)
        let cur = SettingsStore.normalizedCaptureDestination(forStored: settings.captureDestination)
        guard let i = opts.firstIndex(of: cur) else {
            settings.captureDestination = opts[0]
            return
        }
        let n = opts.count
        settings.captureDestination = opts[((i + delta) % n + n) % n]
    }

    private func cycleAutoHide(_ delta: Int) {
        let all = AutoHideBarOption.allCases
        guard let i = all.firstIndex(of: resolvedAutoHideBarOption) else { return }
        let n = all.count
        let next = all[((i + delta) % n + n) % n]
        settings.emuMenuAutoHideBarRaw = next.rawValue
    }

    private func cycleHostEmulationSpeed(_ delta: Int) {
        let opts = SettingsStore.hostEmulationSpeedOptions.map(\.value)
        let cur = settings.hostEmulationSpeed
        let i: Int = {
            if let j = opts.firstIndex(where: { abs(Double($0 - cur)) < 0.0001 }) { return j }
            return opts.enumerated().min(by: { abs($0.element - cur) < abs($1.element - cur) })?.offset ?? 0
        }()
        let n = opts.count
        settings.hostEmulationSpeed = opts[((i + delta) % n + n) % n]
    }

    private func cycleCpuFreqScale(_ delta: Int) {
        let vals = SettingsStore.cpuFreqScaleOptions.map(\.value)
        let cur = settings.cpuFreqScale
        guard let i = vals.firstIndex(of: cur) else { return }
        let n = vals.count
        settings.cpuFreqScale = vals[((i + delta) % n + n) % n]
    }

    private func cycleAspect(_ delta: Int) {
        let opts = [2, 3]
        let cur = opts.contains(settings.aspectRatio) ? settings.aspectRatio : 2
        guard let i = opts.firstIndex(of: cur) else { return }
        let n = opts.count
        settings.aspectRatio = opts[((i + delta) % n + n) % n]
    }

    private func cycleUpscale(_ delta: Int) {
        let vals = SettingsStore.upscaleMultiplierOptions.map(\.value)
        guard let i = vals.firstIndex(of: settings.upscaleMultiplier) else { return }
        let n = vals.count
        settings.upscaleMultiplier = vals[((i + delta) % n + n) % n]
    }

    private func cycleDither(_ delta: Int) {
        let vals = SettingsStore.ditherModeOptions.map(\.value)
        let cur = vals.contains(settings.ditherMode) ? settings.ditherMode : "1x(native)"
        guard let i = vals.firstIndex(of: cur) else { return }
        let n = vals.count
        settings.ditherMode = vals[((i + delta) % n + n) % n]
    }

    private func cyclePGXP(_ delta: Int) {
        let vals = SettingsStore.pgxpModeOptions.map(\.value)
        let cur = vals.contains(settings.pgxpMode) ? settings.pgxpMode : "disabled"
        guard let i = vals.firstIndex(of: cur) else { return }
        let n = vals.count
        settings.pgxpMode = vals[((i + delta) % n + n) % n]
    }

    private func cycleCropOverscan(_ delta: Int) {
        let vals = SettingsStore.cropOverscanOptions.map(\.value)
        let cur = vals.contains(settings.cropOverscan) ? settings.cropOverscan : "smart"
        guard let i = vals.firstIndex(of: cur) else { return }
        let n = vals.count
        settings.cropOverscan = vals[((i + delta) % n + n) % n]
    }

    private func cycleDeinterlacer(_ delta: Int) {
        let vals = SettingsStore.ps1DeinterlacerOptions.map(\.value)
        let cur = vals.contains(settings.ps1Deinterlacer) ? settings.ps1Deinterlacer : "bob"
        guard let i = vals.firstIndex(of: cur) else { return }
        let n = vals.count
        settings.ps1Deinterlacer = vals[((i + delta) % n + n) % n]
    }

    private func cycleColorDepth(_ delta: Int) {
        let vals = SettingsStore.internalColorDepthOptions.map(\.value)
        let cur = vals.contains(settings.internalColorDepth)
            ? settings.internalColorDepth
            : SettingsStore.internalColorDepthOptions[0].value
        guard let i = vals.firstIndex(of: cur) else { return }
        let n = vals.count
        settings.internalColorDepth = vals[((i + delta) % n + n) % n]
    }

    private func cycleNeuralFrame(_ delta: Int) {
        let opts = NeuralUpscaleRegistry.frameUpscaleCycleOptions().map(\.value)
        let cur = settings.neuralUpscaleLive ? settings.neuralUpscaleModelToken : NeuralUpscaleRegistry.frameUpscaleOffToken
        guard let i = opts.firstIndex(of: cur) else {
            settings.neuralUpscaleLive = false
            return
        }
        let n = opts.count
        let next = opts[((i + delta) % n + n) % n]
        if next == NeuralUpscaleRegistry.frameUpscaleOffToken {
            settings.neuralUpscaleLive = false
        } else {
            settings.neuralUpscaleModelToken = next
            settings.neuralUpscaleLive = true
        }
    }

    private func notifyEmuMenuSettingNotification(for row: String) {
        if row.hasPrefix("saveSlot_") { return }
        let n = SakuraNotificationCenter.shared
        func yn(_ v: Bool) -> String { v ? SakuraL10n.tr("common.on") : SakuraL10n.tr("common.off") }
        func osd(_ k: String) -> String {
            SakuraL10n.trf("emu.notify.osdWithMetric", SakuraL10n.tr(k))
        }
        switch row {
        case "editLayout": return
        case "pauseOnMenu":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.pauseInMenu"), detail: yn(settings.pauseOnMenuEnabled))
        case "keepSubmenus":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.keepSubmenusOpen"), detail: yn(settings.emuMenuKeepSubmenusOpen))
        case "preventSleep":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.keepScreenOn"), detail: yn(settings.emuMenuPreventScreenSleep))
        case "autoHide":
            n.postSettingChange(title: SakuraL10n.tr("osd.tile.autoHideTopBar"), detail: resolvedAutoHideBarOption.localizedLabel)
        case "confirmStop":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.confirmStop"), detail: yn(settings.emuMenuConfirmOnStop))
        case "inAppScreenRecord":
            n.postSettingChange(
                title: SakuraL10n.tr("emu.inAppRecord.title"),
                detail: screenRecorder.isRecording
                    ? SakuraL10n.tr("emu.inAppRecord.actionStop") : SakuraL10n.tr("emu.inAppRecord.actionStart")
            )
        case "captureHideWhileRecording":
            let lab = SettingsStore.localizedCaptureScopeOptions()
                .first(where: {
                    $0.value == SettingsStore.normalizedCaptureScope(forStored: settings.captureScope)
                })?.label
            n.postSettingChange(title: SakuraL10n.tr("general.capture.whileRecording"), detail: lab)
        case "captureDestination":
            let lab = SettingsStore.localizedCaptureDestinationOptions()
                .first(where: {
                    $0.value == SettingsStore.normalizedCaptureDestination(forStored: settings.captureDestination)
                })?.label
            n.postSettingChange(title: SakuraL10n.tr("general.capture.saveTo"), detail: lab)
        case "captureTopBarSwap":
            n.postSettingChange(title: SakuraL10n.tr("general.capture.topBarSwap"), detail: yn(settings.topBarSwapSpeedForRecord))
        case "secondaryGameplayPresentation":
            let detail: String
            switch SecondaryDisplayCoordinator.shared.mode {
            case .handheld: detail = SakuraL10n.tr("emu.menu.secondaryGameplay.handheld")
            case .tv:       detail = SakuraL10n.tr("emu.menu.secondaryGameplay.tv")
            }
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.secondaryGameplayPresentation"), detail: detail)
        case "perfHostSpeed":
            let label = SettingsStore.hostEmulationSpeedOptions.first(where: { abs($0.value - settings.hostEmulationSpeed) < 0.0001 })?.label
            n.postSettingChange(title: SakuraL10n.tr("general.tile.speed"), detail: label)
        case "audioTimeStretch":
            n.postSettingChange(title: SakuraL10n.tr("general.tile.timeStretch"), detail: yn(settings.audioTimeStretch))
        case "audioMuteTurbo":
            n.postSettingChange(title: SakuraL10n.tr("general.tile.muteTurbo"), detail: yn(settings.muteAudioWhenTurbo))
        case "perfCPU":
            let label = SettingsStore.cpuFreqScaleOptions.first(where: { $0.value == settings.cpuFreqScale })?.label
            n.postSettingChange(title: SakuraL10n.tr("general.tile.cpuFreq"), detail: label)
        case "haptic":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.haptics"), detail: yn(settings.hapticFeedback))
        case "gfxAspect":
            n.postSettingChange(
                title: SakuraL10n.tr("graphics.tile.aspectRatioMenu"),
                detail: settings.aspectRatio == 3 ? SakuraL10n.tr("graphics.aspect.fill") : SakuraL10n.tr("graphics.aspect.43")
            )
        case "gfxCropOverscan":
            let label = SettingsStore.localizedCropOverscanOptions().first(where: { $0.value == settings.cropOverscan })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.cropOverscan"), detail: label)
        case "gfxDeinterlacer":
            let label = SettingsStore.localizedPs1DeinterlacerOptions().first(where: { $0.value == settings.ps1Deinterlacer })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.ps1Deinterlacer"), detail: label)
        case "gfxResolution":
            let label = SettingsStore.upscaleMultiplierOptions.first(where: { $0.value == settings.upscaleMultiplier })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.internalResolution"), detail: label)
        case "gfxNativeDrawable":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.nativeMetalDrawable"), detail: yn(settings.nativeScaleMetalDrawable))
        case "gfxTextureFilter":
            let label = SettingsStore.textureFilteringOptions.first(where: { $0.value == settings.textureFiltering })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.textureFiltering"), detail: label)
        case "gfxNeuralUpscale":
            let tok = settings.neuralUpscaleLive ? settings.neuralUpscaleModelToken : NeuralUpscaleRegistry.frameUpscaleOffToken
            let label = NeuralUpscaleRegistry.frameUpscaleCycleOptions().first(where: { $0.value == tok })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.neuralUpscale"), detail: label)
        case "gfxFXAA":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.fxaa"), detail: yn(settings.fxaa))
        case "gfxSMAA":
            let label = SettingsStore.localizedSmaaQualityOptions().first(where: { $0.value == settings.smaaQuality })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.smaa"), detail: label)
        case "gfxSMAAPixelArt":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.smaa.pixelArt"), detail: yn(settings.smaaPixelArtMode))
        case "gfxSMAAAdaptive":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.smaa.adaptive"), detail: yn(settings.smaaAdaptiveThreshold))
        case "gfxCAS":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.cas"), detail: yn(settings.casMode != 0))
        case "gfxPGXP":
            let label = SettingsStore.localizedPgxpModeOptions().first(where: { $0.value == settings.pgxpMode })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.pgxp"), detail: label)
        case "gfxWidescreen":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.widescreenHack"), detail: yn(settings.widescreenHack))
        case "gfxColorAdjust":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.colorAdjust"), detail: yn(settings.colorAdjustEnabled))
        case "gfxHdrGrade":
            guard PresentationColor.extendedBrightnessAvailable else { return }
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrEnabled"), detail: yn(settings.colorAdjustHdrEnabled))
        case "gfxDither":
            let label = SettingsStore.localizedDitherModeOptions().first(where: { $0.value == settings.ditherMode })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.dithering"), detail: label)
        case "gfxColorDepth":
            let label = SettingsStore.localizedInternalColorDepthOptions().first(where: { $0.value == settings.internalColorDepth })?.label
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.internalColorDepth"), detail: label)
        case "gfxFrameDuping":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.frameDuping"), detail: yn(settings.frameDuping))
        case "gfxSpatialScaler":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.metalFXTexture"), detail: yn(settings.metalFXTexture))
        case "gfxFrameInterp":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.metalFXFrameInterpolation"), detail: yn(settings.metalFXFrameInterpolation))
        case "gfxTemporalDisplay":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.metalFXTemporalDisplay"), detail: yn(settings.metalFXTemporalDisplay))
        case "gfxMainThreadMetalPresent":
            n.postSettingChange(title: SakuraL10n.tr("general.tile.mainThreadPresent"), detail: yn(settings.mainThreadMetalPresentEnabled))
        case "gfxVideotoolbox":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.videotoolboxFrameFeatures"), detail: yn(settings.videotoolboxFrameFeatures))
        case "gfxReset":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.resetGraphics"), detail: SakuraL10n.tr("emu.notify.resetToDefaults"))
        case "hudEnable":
            n.postSettingChange(title: SakuraL10n.tr("osd.tile.hudEnabled"), detail: yn(settings.hudEnabled))
        case "hudFPS":
            n.postSettingChange(title: osd("osd.tile.hudFps"), detail: yn(settings.hudShowFPS))
        case "hudSpeed":
            n.postSettingChange(title: osd("osd.tile.hudSpeed"), detail: yn(settings.hudShowSpeed))
        case "hudFrame":
            n.postSettingChange(title: osd("osd.tile.hudFrameTime"), detail: yn(settings.hudShowFrameTime))
        case "hudCPU":
            n.postSettingChange(title: osd("osd.tile.hudCpu"), detail: yn(settings.hudShowCPU))
        case "hudRAM":
            n.postSettingChange(title: osd("osd.tile.hudRam"), detail: yn(settings.hudShowRAM))
        case "hudGPU":
            n.postSettingChange(title: osd("osd.tile.hudGpu"), detail: yn(settings.hudShowGPU))
        case "hudRes":
            n.postSettingChange(title: osd("osd.tile.hudResolution"), detail: yn(settings.hudShowResolution))
        case "hudThermal":
            n.postSettingChange(title: osd("osd.tile.hudThermal"), detail: yn(settings.hudShowTemperature))
        case "hudBattery":
            n.postSettingChange(title: osd("osd.tile.hudBattery"), detail: yn(settings.hudShowBattery))
        case "hudGraphs":
            n.postSettingChange(title: osd("osd.tile.hudGraphs"), detail: yn(settings.hudShowGraphs))
        case "hudReset":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.resetHudPosition"), detail: SakuraL10n.tr("emu.notify.actionReset"))
        case "resetLayout":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.resetPosition"), detail: SakuraL10n.tr("emu.notify.actionReset"))
        case "padOpacity":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.padOpacity"), detail: String(format: "%.0f%%", Double(settings.padOpacity * 100)))
        case "audioLatency":
            n.postSettingChange(title: SakuraL10n.tr("emu.menu.audioLatency"), detail: SakuraL10n.trf("emu.menu.latencyMsFmt", Float(settings.audioLatency)))
        case "gfxColorSaturation":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentSaturation"), detail: String(format: "%.2f", settings.displayColorSaturation))
        case "gfxColorBrightness":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentBrightness"), detail: String(format: "%.2f", settings.colorAdjustBrightness))
        case "gfxColorContrast":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentContrast"), detail: String(format: "%.2f", settings.colorAdjustContrast))
        case "gfxColorVibrance":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentVibrance"), detail: String(format: "%.2f", settings.colorAdjustVibrance))
        case "gfxColorExposure":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentExposure"), detail: String(format: "%.2f", settings.colorAdjustExposure))
        case "gfxColorGamma":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentGamma"), detail: String(format: "%.2f", settings.colorAdjustGamma))
        case "gfxColorTemperature":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentColorTemp"), detail: String(format: "%.2f", settings.colorAdjustColorTemperature))
        case "gfxColorSharpness":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentSharpness"), detail: String(format: "%.2f", settings.colorAdjustSharpness))
        case "gfxColorBloom":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentBloom"), detail: String(format: "%.2f", settings.colorAdjustBloom))
        case "gfxColorBloomRadius":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentBloomRadius"), detail: String(format: "%.2f", settings.colorAdjustBloomRadius))
        case "gfxColorVignette":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentVignette"), detail: String(format: "%.2f", settings.colorAdjustVignette))
        case "gfxColorVignetteRadius":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.presentVignetteRadius"), detail: String(format: "%.2f", settings.colorAdjustVignetteRadius))
        case "gfxHdrExposure":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrExposure"), detail: String(format: "%.2f", settings.colorAdjustHdrExposure))
        case "gfxHdrSaturation":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrSaturation"), detail: String(format: "%.2f", settings.colorAdjustHdrSaturation))
        case "gfxHdrContrast":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrContrast"), detail: String(format: "%.2f", settings.colorAdjustHdrContrast))
        case "gfxHdrBloom":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrBloom"), detail: String(format: "%.2f", settings.colorAdjustHdrBloom))
        case "gfxHdrShadowLift":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrShadowLift"), detail: String(format: "%.2f", settings.colorAdjustHdrShadowLift))
        case "gfxHdrHighlightCompress":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.hdrHighlightRollOff"), detail: String(format: "%.2f", settings.colorAdjustHdrHighlightCompress))
        case "gfxCASSharpness":
            n.postSettingChange(title: SakuraL10n.tr("graphics.tile.casSharpness"), detail: "\(settings.casSharpness)")
        default:
            break
        }
    }

    private func activateEmuMenuRow(_ row: String) {
        switch row {
        case "pauseOnMenu": settings.pauseOnMenuEnabled.toggle()
        case "keepSubmenus": settings.emuMenuKeepSubmenusOpen.toggle()
        case "preventSleep": settings.emuMenuPreventScreenSleep.toggle()
        case "autoHide": cycleAutoHide(1)
        case "confirmStop": settings.emuMenuConfirmOnStop.toggle()
        case "inAppScreenRecord": screenRecorder.toggleRecording()
        case "captureHideWhileRecording": cycleCaptureScope(1)
        case "captureDestination": cycleCaptureDestination(1)
        case "captureTopBarSwap": settings.topBarSwapSpeedForRecord.toggle()
        case "secondaryGameplayPresentation":
            let order: [SecondaryGameplayPresentationMode] = [.handheld, .tv]
            if let i = order.firstIndex(of: secondaryDisplay.mode) {
                secondaryDisplay.mode = order[(i + 1) % order.count]
            } else {
                secondaryDisplay.mode = .handheld
            }
        case "perfHostSpeed": cycleHostEmulationSpeed(1)
        case "audioTimeStretch": settings.audioTimeStretch.toggle()
        case "audioMuteTurbo": settings.muteAudioWhenTurbo.toggle()
        case "perfCPU": cycleCpuFreqScale(1)
        case "haptic": settings.hapticFeedback.toggle()
        case "gfxAspect": cycleAspect(1)
        case "gfxCropOverscan": cycleCropOverscan(1)
        case "gfxDeinterlacer": cycleDeinterlacer(1)
        case "gfxResolution": cycleUpscale(1)
        case "gfxNativeDrawable": settings.nativeScaleMetalDrawable.toggle()
        case "gfxTextureFilter": settings.textureFiltering = cycleIntWrappingInRange(settings.textureFiltering, 0...7, 1)
        case "gfxNeuralUpscale": cycleNeuralFrame(1)
        case "gfxFXAA": settings.fxaa.toggle()
        case "gfxSMAA": settings.smaaQuality = (settings.smaaQuality + 1) % 5
        case "gfxSMAAPixelArt": settings.smaaPixelArtMode.toggle()
        case "gfxSMAAAdaptive": settings.smaaAdaptiveThreshold.toggle()
        case "gfxCAS": settings.casMode = settings.casMode == 0 ? 1 : 0
        case "gfxPGXP": cyclePGXP(1)
        case "gfxWidescreen": settings.widescreenHack.toggle()
        case "gfxColorAdjust":
            settings.colorAdjustEnabled.toggle()
        case "gfxHdrGrade":
            if PresentationColor.extendedBrightnessAvailable {
                settings.colorAdjustHdrEnabled.toggle()
            }
        case "gfxDither": cycleDither(1)
        case "gfxColorDepth": cycleColorDepth(1)
        case "gfxFrameDuping": settings.frameDuping.toggle()
        case "gfxSpatialScaler": settings.metalFXTexture.toggle()
        case "gfxFrameInterp": settings.metalFXFrameInterpolation.toggle()
        case "gfxTemporalDisplay": settings.metalFXTemporalDisplay.toggle()
        case "gfxMainThreadMetalPresent": settings.mainThreadMetalPresentEnabled.toggle()
        case "gfxVideotoolbox": settings.videotoolboxFrameFeatures.toggle()
        case "gfxReset": settings.resetGraphicsDefaults()
        case "hudEnable": settings.hudEnabled.toggle()
        case "hudFPS": settings.hudShowFPS.toggle()
        case "hudSpeed": settings.hudShowSpeed.toggle()
        case "hudFrame": settings.hudShowFrameTime.toggle()
        case "hudCPU": settings.hudShowCPU.toggle()
        case "hudRAM": settings.hudShowRAM.toggle()
        case "hudGPU": settings.hudShowGPU.toggle()
        case "hudRes": settings.hudShowResolution.toggle()
        case "hudThermal": settings.hudShowTemperature.toggle()
        case "hudBattery": settings.hudShowBattery.toggle()
        case "hudGraphs": settings.hudShowGraphs.toggle()
        case "hudReset":
            UserDefaults.standard.removeObject(forKey: "sakura.hud.positionX")
            UserDefaults.standard.removeObject(forKey: "sakura.hud.positionY")
            UserDefaults.standard.set(0.0, forKey: "sakura.hud.relOffsetX")
            UserDefaults.standard.set(0.0, forKey: "sakura.hud.relOffsetY")
        case "editLayout":
            dismissGameMenu()
            layout.syncLayoutPresetFromBridge()
            withAnimation(theme.layoutEditSpringAnimation) { isEditMode = true }
        case "resetLayout":
            layout.reset()
            selectedGroupID = ""
        case let s where s.hasPrefix("saveSlot_"):
            guard settings.saveStatesEnabled else { break }
            if let n = Int(s.dropFirst("saveSlot_".count)) {
                if SakuraBridge.saveState(toSlot: Int32(n)) {
                    attachScreenshotIfRequested()
                }
                refreshSaveStateRows()
                HapticManager.firePrimary()
            }
        default:
            break
        }
        notifyEmuMenuSettingNotification(for: row)
        switch row {
        case "hudEnable", "gfxColorAdjust", "gfxHdrGrade", "gfxCAS", "gfxSMAA", "secondaryGameplayPresentation":
            rebuildEmuMenuFocusOrder()
        default:
            break
        }
    }

    private var ps1BootGameKey: String { SakuraBridge.currentISOPath() ?? "" }

    private func secondaryEmuMenuRow(_ row: String) {
        if row.hasPrefix("saveSlot_"), settings.saveStatesEnabled, let n = Int(row.dropFirst("saveSlot_".count)) {
            guard SakuraBridge.hasSaveState(inSlot: Int32(n)) else {
                SFXManager.shared.play(.error)
                return
            }
            _ = SakuraBridge.loadState(fromSlot: Int32(n))
            refreshSaveStateRows()
            HapticManager.firePrimary()
            return
        }
        if gameplaySettingsSheetRowIsPicker(row) || gameplaySettingsSheetRowIsSlider(row) {
            nudgeEmuMenuField(row: row, delta: -1)
            notifyEmuMenuSettingNotification(for: row)
        }
    }

    private func openGameMenu() {
        guard !isEditMode else { return }
        if settings.saveStatesEnabled {
            refreshSaveStateRows()
        }
        if settings.pauseOnMenuEnabled {
            if !SakuraBridge.isEmulationPaused() {
                SakuraBridge.setEmulationPaused(true)
                didPauseForMenu = true
            }
        }
        emulationPausedForUI = SakuraBridge.isEmulationPaused()
        withAnimation(theme.emuMenuPresentAnimation) {
            showingEmulationMenu = true
        }
    }

    private func dismissGameMenu() {
        guard showingEmulationMenu else { return }
        if didPauseForMenu {
            SakuraBridge.setEmulationPaused(false)
            didPauseForMenu = false
        }
        emulationPausedForUI = SakuraBridge.isEmulationPaused()
        withAnimation(theme.emuMenuPresentAnimation) {
            showingEmulationMenu = false
        }
    }

    private func stopEmulation() {
        SakuraBridge.requestVMShutdown()
        appState.returnToMenu()
    }

    private var quickLoadSlot: Int? {
        let _ = saveStateRefreshToken
        var newestSlot: Int?
        var newestDate: Date = .distantPast
        for slot in 1...10 {
            guard SakuraBridge.hasSaveState(inSlot: Int32(slot)) else { continue }
            let d = SakuraBridge.saveStateDate(forSlot: Int32(slot)) ?? .distantPast
            if d > newestDate {
                newestDate = d
                newestSlot = slot
            }
        }
        return newestSlot
    }

    private func quickSaveState() {
        guard settings.saveStatesEnabled else { return }
        let target = quickLoadSlot ?? 1
        if SakuraBridge.saveState(toSlot: Int32(target)) {
            attachScreenshotIfRequested()
        }
        refreshSaveStateRows()
        HapticManager.firePrimary()
    }

    private func attachScreenshotIfRequested() {
        guard settings.mediaScreenshotOnSaveState else { return }
        screenRecorder.captureGameplayScreenshotPNG(attachEmbeddedSaveSnapshot: false)
    }

    private func quickLoadState() {
        guard settings.saveStatesEnabled else { return }
        guard let slot = quickLoadSlot else { return }
        _ = SakuraBridge.loadState(fromSlot: Int32(slot))
        refreshSaveStateRows()
        HapticManager.firePrimary()
    }

    private func reloadGame() {
        if let n = appState.runningGameName, n != "BIOS" {
            appState.shutdownAndBoot(isoName: n)
        }
    }
}

#if DEBUG
#Preview {
    EmulationView()
}
#endif
