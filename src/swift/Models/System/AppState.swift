// SPDX-License-Identifier: GPL-3.0+

import GameController
import SwiftUI
import UIKit

enum CommunityLink {
    static let discordInviteCode = "8KKtyqcsw4"
    static let discordWebURL = URL(string: "https://discord.gg/\(discordInviteCode)")!
    private static let discordAppURL = URL(string: "discord://discord.com/invite/\(discordInviteCode)")!

    @MainActor
    static func openDiscordInvite() {
        let application = UIApplication.shared
        if application.canOpenURL(discordAppURL) {
            application.open(discordAppURL)
        } else {
            application.open(discordWebURL)
        }
    }
}

enum SettingsPage: Int, CaseIterable, Identifiable {
    case general
    case graphics
    case osd
    case controller
    case ui
    case about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: return SakuraL10n.tr("settings.page.general.title")
        case .graphics: return SakuraL10n.tr("settings.page.graphics.title")
        case .osd: return SakuraL10n.tr("settings.page.osd.title")
        case .controller: return SakuraL10n.tr("settings.page.controller.title")
        case .ui: return SakuraL10n.tr("settings.page.ui.title")
        case .about: return SakuraL10n.tr("settings.page.about.title")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return SakuraL10n.tr("settings.page.general.subtitle")
        case .graphics: return SakuraL10n.tr("settings.page.graphics.subtitle")
        case .osd: return SakuraL10n.tr("settings.page.osd.subtitle")
        case .controller: return SakuraL10n.tr("settings.page.controller.subtitle")
        case .ui: return SakuraL10n.tr("settings.page.ui.subtitle")
        case .about: return SakuraL10n.tr("settings.page.about.subtitle")
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .graphics: return "sparkles"
        case .osd: return "gauge.with.dots.needle.67percent"
        case .controller: return "gamecontroller"
        case .ui: return "rectangle.on.rectangle"
        case .about: return "info.circle"
        }
    }

    var topBarCaption: String {
        switch self {
        case .general: return SakuraL10n.tr("settings.page.general.captionShort")
        case .graphics: return SakuraL10n.tr("settings.page.graphics.captionShort")
        case .osd: return SakuraL10n.tr("settings.page.osd.captionShort")
        case .controller: return SakuraL10n.tr("settings.page.controller.captionShort")
        case .ui: return SakuraL10n.tr("settings.page.ui.captionShort")
        case .about: return SakuraL10n.tr("settings.page.about.captionShort")
        }
    }
}

// MARK: - App state

@Observable
final class AppState: @unchecked Sendable {
    static let shared = AppState()

    enum Screen {
        case menu
        case settings
        case playing
        case mediaBrowser
    }

    var currentScreen: Screen = .menu
    var selectedSettingsPage: SettingsPage = AppState.loadStoredSettingsPage() {
        didSet {
            UserDefaults.standard.set(selectedSettingsPage.rawValue, forKey: AppState.settingsPageDefaultsKey)
        }
    }
    var runningGameName: String? = nil
    var hideStatusBar: Bool = false

    @ObservationIgnored private var pendingBootAction: (() -> Void)?
    @ObservationIgnored private var shutdownObserver: NSObjectProtocol?

    // Re-entrancy guard: prevents a second bootGame from launching while a
    // background boot is still in flight. Without this, rapid taps (or a
    // notification + explicit call landing together) could both dispatch to the
    // global queue and race inside bootGameAtPath:, previously crashing with
    // libc++abi: terminating due to std::thread move-assign over a joinable
    // slot. The native side is now also serialized, this just avoids the wasted
    // double init.
    @ObservationIgnored private var isBootInFlight: Bool = false

    private static let settingsPageDefaultsKey = "sakura.settings.selectedPage"

    private static func loadStoredSettingsPage() -> SettingsPage {
        if let raw = UserDefaults.standard.object(forKey: settingsPageDefaultsKey) as? Int,
           let page = SettingsPage(rawValue: raw) {
            return page
        }
        return .graphics
    }

    private init() {
        shutdownObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SakuraVMDidShutdown"),
            object: nil, queue: .main
        ) { [weak self] _ in
            if let running = self?.runningGameName, running != "BIOS" {
                let elapsed = PlaytimeStore.shared.endSession(for: running)
                Task { @MainActor in
                    RatingPromptCoordinator.shared.sessionDidEnd(elapsed: elapsed)
                }
            } else {
                PlaytimeStore.shared.discardSession()
            }
            self?.runningGameName = nil
            if let action = self?.pendingBootAction {
                self?.pendingBootAction = nil
                action()
            } else {
                self?.currentScreen = .menu
            }
            self?.syncExternalDisplayWindow()
        }
    }

    private func syncExternalDisplayWindow() {
        Task { @MainActor in
            SecondaryDisplayCoordinator.shared.syncExternalDisplayContent()
        }
    }

    func bootGame(isoName: String) {
        // Coalesce duplicate boot requests on the main actor. requestVMBoot()
        // runs on DispatchQueue.global, so without this a rapid double-invoke
        // would enqueue two boots back-to-back and both would hit the native
        // core before the first bootGameAtPath: returned.
        if isBootInFlight { return }
        isBootInFlight = true
        SakuraBridge.bootISO(isoName)
        runningGameName = isoName
        currentScreen = .playing
        syncExternalDisplayWindow()
        Task { @MainActor in BackgroundVideo.shared.teardown() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = SakuraBridge.requestVMBoot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBootInFlight = false
                if !ok {
                    self.runningGameName = nil
                    self.currentScreen = .menu
                    self.syncExternalDisplayWindow()
                    self.postBootFailureNotification()
                    return
                }
                PlaytimeStore.shared.beginSession(for: isoName)
                MusicPlayer.shared.pauseForGame()
                SFXManager.shared.suspendForGame()
                HUDModel.shared.start()
            }
        }
    }

    func returnToMenu() {
        if currentScreen == .settings {
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                currentScreen = .menu
            }
        } else {
            currentScreen = .menu
        }
        syncExternalDisplayWindow()
        NotificationCenter.default.post(name: NSNotification.Name("SakuraReturnToMenu"), object: nil)
        Task { @MainActor in
            MusicPlayer.shared.resumeAfterGame()
            SFXManager.shared.resumeAfterGame()
            HUDModel.shared.stop()
        }
    }

    func openMedia() {
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            currentScreen = .mediaBrowser
        }
        syncExternalDisplayWindow()
    }

    func openSettings(page: SettingsPage? = nil) {
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            if let page {
                selectedSettingsPage = page
            }
            if currentScreen != .settings {
                currentScreen = .settings
            }
        }
        syncExternalDisplayWindow()
    }

    func cycleSettingsPage(delta: Int) {
        let all = SettingsPage.allCases
        guard let currentIndex = all.firstIndex(of: selectedSettingsPage) else { return }
        let count = all.count
        let next = ((currentIndex + delta) % count + count) % count
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            selectedSettingsPage = all[next]
        }
    }

    func cycleTopSection(delta: Int) {
        let pages = SettingsPage.allCases
        let total = pages.count + 2

        let currentIdx: Int
        switch currentScreen {
        case .menu: currentIdx = 0
        case .mediaBrowser: currentIdx = 1
        case .settings: currentIdx = (pages.firstIndex(of: selectedSettingsPage) ?? 0) + 2
        case .playing: return
        }

        let nextIdx = ((currentIdx + delta) % total + total) % total
        if nextIdx == 0 {
            returnToMenu()
        } else if nextIdx == 1 {
            openMedia()
        } else {
            openSettings(page: pages[nextIdx - 2])
        }
    }

    var currentTopIndex: Int {
        switch currentScreen {
        case .menu: return 0
        case .mediaBrowser: return 1
        case .settings:
            return (SettingsPage.allCases.firstIndex(of: selectedSettingsPage) ?? 0) + 2
        case .playing: return 0
        }
    }

    func activateTopIndex(_ index: Int) {
        if index <= 0 {
            returnToMenu()
            return
        }
        if index == 1 {
            openMedia()
            return
        }
        let pages = SettingsPage.allCases
        let clamped = max(0, min(pages.count - 1, index - 2))
        openSettings(page: pages[clamped])
    }

    func returnToGame() {
        if runningGameName != nil {
            NotificationCenter.default.post(name: NSNotification.Name("SakuraEnterGameScreen"), object: nil)
            currentScreen = .playing
            syncExternalDisplayWindow()
            Task { @MainActor in
                BackgroundVideo.shared.teardown()
            }
        }
    }

    func shutdownAndBoot(isoName: String) {
        if !SakuraBridge.isEmulationRunning() {
            runningGameName = nil
            pendingBootAction = nil
            bootGame(isoName: isoName)
            return
        }
        pendingBootAction = { [weak self] in
            self?.bootGame(isoName: isoName)
        }
        SakuraBridge.requestVMShutdown()
    }

    func playGame(isoName: String) {
        if SakuraBridge.isEmulationRunning() {
            if isoName == runningGameName {
                returnToGame()
            } else {
                shutdownAndBoot(isoName: isoName)
            }
        } else {
            runningGameName = nil
            pendingBootAction = nil
            bootGame(isoName: isoName)
        }
    }

    private func postBootFailureNotification() {
        Task { @MainActor in
            let bridged = SakuraBridge.lastBootFailureReason() as String?
            let trimmed = bridged?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sub: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
            SakuraNotificationCenter.shared.pushRaw(
                SakuraNotificationCenter.Card(
                    kind: .error,
                    title: SakuraL10n.tr("library.boot.failedTitle"),
                    subtitle: sub,
                    icon: "xmark.octagon.fill",
                    tintKey: "red",
                    introSeconds: 0,
                    persistence: 8
                )
            )
        }
    }
}

// MARK: - Playtime

@Observable
final class PlaytimeStore: @unchecked Sendable {
    static let shared = PlaytimeStore()

    private let defaults = UserDefaults.standard
    private let totalKey = "Sakura.Playtime.Total"
    private let lastKey  = "Sakura.Playtime.LastPlayed"
    private var sessionStart: Date?
    private var sessionFile: String?
    private(set) var version: Int = 0

    private init() {}

    func beginSession(for fileName: String) {
        sessionStart = Date()
        sessionFile = fileName
        var last = defaults.dictionary(forKey: lastKey) as? [String: TimeInterval] ?? [:]
        last[fileName] = Date().timeIntervalSince1970
        defaults.set(last, forKey: lastKey)
        version &+= 1
    }

    @discardableResult
    func endSession(for fileName: String) -> TimeInterval {
        defer {
            sessionStart = nil
            sessionFile = nil
        }
        guard let start = sessionStart, let file = sessionFile, file == fileName else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 1 else { return elapsed }
        var total = defaults.dictionary(forKey: totalKey) as? [String: TimeInterval] ?? [:]
        total[fileName] = (total[fileName] ?? 0) + elapsed
        defaults.set(total, forKey: totalKey)
        version &+= 1
        return elapsed
    }

    func discardSession() {
        sessionStart = nil
        sessionFile = nil
    }

    func totalPlaytime(for fileName: String) -> TimeInterval {
        let total = defaults.dictionary(forKey: totalKey) as? [String: TimeInterval] ?? [:]
        var base = total[fileName] ?? 0
        if let start = sessionStart, sessionFile == fileName {
            base += Date().timeIntervalSince(start)
        }
        return base
    }

    func lastPlayed(for fileName: String) -> Date? {
        let last = defaults.dictionary(forKey: lastKey) as? [String: TimeInterval] ?? [:]
        guard let ts = last[fileName] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    func removePlaytimeRecords(for fileName: String) {
        var total = defaults.dictionary(forKey: totalKey) as? [String: TimeInterval] ?? [:]
        total.removeValue(forKey: fileName)
        defaults.set(total, forKey: totalKey)
        var last = defaults.dictionary(forKey: lastKey) as? [String: TimeInterval] ?? [:]
        last.removeValue(forKey: fileName)
        defaults.set(last, forKey: lastKey)
        if sessionFile == fileName { discardSession() }
        version &+= 1
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.locale = SakuraL10n.effectiveFormatLocale()
        f.calendar = cal
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: seconds) ?? "0"
    }

    static func formatByteCount(_ bytes: UInt64) -> String {
        let clamped = min(bytes, UInt64(Int64.max))
        let value = Int64(bitPattern: clamped)
        return value.formatted(
            .byteCount(style: .file)
                .locale(SakuraL10n.effectiveFormatLocale())
        )
    }

    static func formatLastPlayed(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = SakuraL10n.effectiveFormatLocale()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Gamepad

enum GamepadAction {
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case confirm
    case back
    case secondary
    case tertiary
    case menu
    case shoulderLeft
    case shoulderRight
    case triggerLeft
    case triggerRight
    case captureCancel
}

enum GamepadContext {
    case inactive
    case library
    case settings
    case emulation
    case emulationMenu
    case mediaViewer
}

@Observable
final class GamepadNavigation: @unchecked Sendable {
    static let shared = GamepadNavigation()

    var isActive = false
    var isPlayStation = false
    var context: GamepadContext = .inactive
    var lastAction: GamepadAction?
    var actionID = 0
    var focusedSettingsIndex = 0
    /// GCKeyboard attached (Magic Keyboard, etc.). Drives shell focus same as a gamepad.
    var hasHardwareKeyboard = false

    /// Synced from `SecondaryDisplayCoordinator` so shell UI updates when AirPlay / external raster toggles.
    var secondaryRasterShellBrowsing = false

    var shellNavInputActive: Bool {
        isActive || hasHardwareKeyboard || secondaryRasterShellBrowsing
    }

    // pass externalRasterSurfaceAvailable when updating from inside SecondaryDisplayCoordinator so this does not re-enter SecondaryDisplayCoordinator.shared during its dispatch_once init.
    @MainActor
    func syncSecondaryRasterShellNavFlag(externalRasterSurfaceAvailable rasterOverride: Bool? = nil) {
        let rasterOn = rasterOverride ?? SecondaryDisplayCoordinator.shared.externalRasterSurfaceAvailable
        let v = rasterOn && AppState.shared.currentScreen != .playing
        if secondaryRasterShellBrowsing != v {
            secondaryRasterShellBrowsing = v
        }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyboardObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var joystickCooldown = false
    @ObservationIgnored private var dpadCooldown = false
    @ObservationIgnored private var leftShoulderActive = false
    @ObservationIgnored private var rightShoulderActive = false
    @ObservationIgnored private var leftTriggerActive = false
    @ObservationIgnored private var rightTriggerActive = false

    @ObservationIgnored private var dpadHoldInitial: DispatchWorkItem?
    @ObservationIgnored private var dpadHoldStep: DispatchWorkItem?
    @ObservationIgnored private var dpadHoldAction: GamepadAction?

    @ObservationIgnored private var shoulderHoldInitial: DispatchWorkItem?
    @ObservationIgnored private var shoulderHoldStep: DispatchWorkItem?
    @ObservationIgnored private var shoulderHoldIsLeft: Bool?

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reloadConnectedControllers()
            },
            center.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reloadConnectedControllers()
            },
            center.addObserver(
                forName: .GCControllerDidBecomeCurrent,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reloadConnectedControllers()
            },
        ]

        if #available(iOS 14.0, *) {
            keyboardObservers = [
                center.addObserver(
                    forName: .GCKeyboardDidConnect,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.refreshHardwareKeyboardState()
                },
                center.addObserver(
                    forName: .GCKeyboardDidDisconnect,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.refreshHardwareKeyboardState()
                },
            ]
            refreshHardwareKeyboardState()
        }

        reloadConnectedControllers()
        Task { @MainActor in
            self.syncSecondaryRasterShellNavFlag()
        }
    }

    @available(iOS 14.0, *)
    private func refreshHardwareKeyboardState() {
        hasHardwareKeyboard = GCKeyboard.coalesced != nil
    }

    func syncHardwareKeyboardFromSystem() {
        if #available(iOS 14.0, *) {
            refreshHardwareKeyboardState()
        }
    }

    func applyKeyboardNavigationAction(_ action: GamepadAction) {
        switch action {
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            fireDpad(action)
        default:
            fire(action)
        }
    }

    var confirmLabel: String { isPlayStation ? "✕" : "A" }
    var backLabel: String { isPlayStation ? "○" : "B" }
    var secondaryLabel: String { isPlayStation ? "☐" : "X" }
    var tertiaryLabel: String { isPlayStation ? "△" : "Y" }
    var menuLabel: String { isPlayStation ? "Options" : "Menu" }

    func enterLibrary() {
        context = .library
    }

    func enterSettings() {
        context = .settings
        focusedSettingsIndex = 0
    }

    func leave(_ expectedContext: GamepadContext) {
        if context == expectedContext {
            context = .inactive
        }
    }

    func enterEmulation() {
        context = .emulation
    }

    func enterMediaViewer() {
        context = .mediaViewer
    }

    func enterEmulationMenu() {
        context = .emulationMenu
    }

    func leaveEmulationMenu() {
        if context == .emulationMenu {
            context = .emulation
        }
    }

    func leaveEmulation() {
        if context == .emulation || context == .emulationMenu {
            context = .inactive
        }
    }

    private func reloadConnectedControllers() {
        if let controller = preferredNavigableController() {
            handleConnectedController(controller)
        } else {
            cancelDpadHoldRepeat()
            cancelShoulderHoldRepeat()
            isActive = false
        }
    }

    /// Prefer the system "current" game controller (Control Center / last used) so
    /// navigation and remaps track the pad the user actually plays with.
    private func preferredNavigableController() -> GCController? {
        let usable = usableControllers()
        guard !usable.isEmpty else { return nil }
        if #available(iOS 14.0, *) {
            if let cur = GCController.current, usable.contains(where: { $0 === cur }) {
                return cur
            }
        }
        return usable.first
    }

    private func handleConnectedController(_ controller: GCController) {
        guard Self.hasNavigableProfile(controller), !Self.isLikelyVirtualController(controller) else { return }
        cancelDpadHoldRepeat()
        cancelShoulderHoldRepeat()
        detectControllerType(controller)
        configureController(controller)
        isActive = true
    }

    private func detectControllerType(_ controller: GCController) {
        let name = (controller.vendorName ?? "").lowercased()
        isPlayStation =
            name.contains("dualshock") || name.contains("dualsense") || name.contains("playstation")
            || name.contains("ps4") || name.contains("ps5") || name.contains("sony")
    }

    private func configureController(_ controller: GCController) {
        if let gamepad = controller.extendedGamepad {
            configureExtendedGamepad(gamepad)
        } else if let gamepad = controller.microGamepad {
            configureMicroGamepad(gamepad)
        }
    }

    private func configureExtendedGamepad(_ gamepad: GCExtendedGamepad) {
        gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveLeft, pressed: pressed) }
        }
        gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveRight, pressed: pressed) }
        }
        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveUp, pressed: pressed) }
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveDown, pressed: pressed) }
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.confirm) }
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.back) }
        }
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.secondary) }
        }
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.tertiary) }
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.menu) }
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.leftShoulderActive = pressed
                if pressed {
                    if self.rightShoulderActive {
                        self.cancelShoulderHoldRepeat()
                        self.fire(.captureCancel)
                    } else {
                        self.startShoulderHoldRepeat(isLeft: true)
                    }
                } else {
                    self.endShoulderHoldIfReleased(isLeft: true)
                }
            }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rightShoulderActive = pressed
                if pressed {
                    if self.leftShoulderActive {
                        self.cancelShoulderHoldRepeat()
                        self.fire(.captureCancel)
                    } else {
                        self.startShoulderHoldRepeat(isLeft: false)
                    }
                } else {
                    self.endShoulderHoldIfReleased(isLeft: false)
                }
            }
        }
        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            let active = value > 0.5
            if active && !(self?.leftTriggerActive ?? false) {
                self?.leftTriggerActive = true
                DispatchQueue.main.async { self?.fire(.triggerLeft) }
            } else if !active {
                self?.leftTriggerActive = false
            }
        }
        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            let active = value > 0.5
            if active && !(self?.rightTriggerActive ?? false) {
                self?.rightTriggerActive = true
                DispatchQueue.main.async { self?.fire(.triggerRight) }
            } else if !active {
                self?.rightTriggerActive = false
            }
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            DispatchQueue.main.async { self?.handleThumbstick(x: x, y: y) }
        }
    }

    private func configureMicroGamepad(_ gamepad: GCMicroGamepad) {
        gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveLeft, pressed: pressed) }
        }
        gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveRight, pressed: pressed) }
        }
        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveUp, pressed: pressed) }
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.handleDpadDirection(.moveDown, pressed: pressed) }
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.confirm) }
        }
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.back) }
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.fire(.menu) }
        }
    }

    private func handleThumbstick(x: Float, y: Float) {
        guard allowsGamepadNavigationEvents else { return }
        guard !joystickCooldown else { return }
        let horizontalThreshold: Float = 0.55
        let verticalThreshold: Float = 0.70

        if abs(x) > abs(y) {
            if x > horizontalThreshold {
                fire(.moveRight)
                startCooldown()
            } else if x < -horizontalThreshold {
                fire(.moveLeft)
                startCooldown()
            }
        } else {
            if y > verticalThreshold {
                fire(.moveUp)
                startCooldown()
            } else if y < -verticalThreshold {
                fire(.moveDown)
                startCooldown()
            }
        }
    }

    private func startCooldown() {
        joystickCooldown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.joystickCooldown = false
        }
    }

    private var allowsGamepadNavigationEvents: Bool {
        switch context {
        case .library, .settings, .emulationMenu, .mediaViewer: return true
        case .inactive, .emulation: return false
        }
    }

    private func cancelDpadHoldRepeat() {
        dpadHoldInitial?.cancel()
        dpadHoldStep?.cancel()
        dpadHoldInitial = nil
        dpadHoldStep = nil
        dpadHoldAction = nil
    }

    private func handleDpadDirection(_ action: GamepadAction, pressed: Bool) {
        switch action {
        case .moveLeft, .moveRight, .moveUp, .moveDown: break
        default: return
        }
        if pressed {
            cancelDpadHoldRepeat()
            dpadHoldAction = action
            fireDpad(action)
            let initial = DispatchWorkItem { [weak self] in
                self?.dpadHoldRepeatStep(action)
            }
            dpadHoldInitial = initial
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: initial)
        } else if dpadHoldAction == action {
            cancelDpadHoldRepeat()
        }
    }

    private func dpadHoldRepeatStep(_ action: GamepadAction) {
        guard dpadHoldAction == action else { return }
        guard allowsGamepadNavigationEvents else {
            cancelDpadHoldRepeat()
            return
        }
        fire(action)
        let step = DispatchWorkItem { [weak self] in
            self?.dpadHoldRepeatStep(action)
        }
        dpadHoldStep = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: step)
    }

    private func cancelShoulderHoldRepeat() {
        shoulderHoldInitial?.cancel()
        shoulderHoldStep?.cancel()
        shoulderHoldInitial = nil
        shoulderHoldStep = nil
        shoulderHoldIsLeft = nil
    }

    private func startShoulderHoldRepeat(isLeft: Bool) {
        cancelShoulderHoldRepeat()
        guard allowsGamepadNavigationEvents else { return }
        shoulderHoldIsLeft = isLeft
        fire(isLeft ? .shoulderLeft : .shoulderRight)
        let initial = DispatchWorkItem { [weak self] in
            self?.shoulderHoldRepeatStep(isLeft: isLeft)
        }
        shoulderHoldInitial = initial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: initial)
    }

    private func shoulderHoldRepeatStep(isLeft: Bool) {
        guard shoulderHoldIsLeft == isLeft else { return }
        guard allowsGamepadNavigationEvents else {
            cancelShoulderHoldRepeat()
            return
        }
        fire(isLeft ? .shoulderLeft : .shoulderRight)
        let step = DispatchWorkItem { [weak self] in
            self?.shoulderHoldRepeatStep(isLeft: isLeft)
        }
        shoulderHoldStep = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: step)
    }

    private func endShoulderHoldIfReleased(isLeft: Bool) {
        if shoulderHoldIsLeft == isLeft {
            cancelShoulderHoldRepeat()
        }
    }

    private func fireDpad(_ action: GamepadAction) {
        guard allowsGamepadNavigationEvents else { return }
        guard !dpadCooldown else { return }
        dpadCooldown = true
        fire(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.dpadCooldown = false
        }
    }

    /// Synthesize a shell-nav action from non-gamepad input (e.g., the phone's
    /// virtual pad while browsing on an external display). Gated on the same
    /// "allowed" check as physical gamepads so we never fire into gameplay.
    @MainActor
    func injectShellAction(_ action: GamepadAction) {
        fire(action)
    }

    private func fire(_ action: GamepadAction) {
        guard allowsGamepadNavigationEvents else { return }
        lastAction = action
        actionID &+= 1
    }

    private func usableControllers() -> [GCController] {
        GCController.controllers().filter {
            Self.hasNavigableProfile($0) && !Self.isLikelyVirtualController($0)
        }
    }

    private static func isLikelyVirtualController(_ controller: GCController) -> Bool {
        NSStringFromClass(type(of: controller) as AnyClass).contains("GCVirtualController")
    }

    private static func hasNavigableProfile(_ controller: GCController) -> Bool {
        controller.extendedGamepad != nil || controller.microGamepad != nil
    }
}
