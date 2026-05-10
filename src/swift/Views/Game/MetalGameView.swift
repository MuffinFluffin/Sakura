// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit
import QuartzCore

extension Notification.Name {
    static let sakuraUpscaleMultiplierChanged = Notification.Name("SakuraUpscaleMultiplierChanged")
    static let sakuraMainThreadMetalPresentChanged = Notification.Name("SakuraMainThreadMetalPresentChanged")
    static let sakuraNativeScaleDrawableChanged = Notification.Name("SakuraNativeScaleDrawableChanged")
}

// True when the view hierarchy is being rendered onto the external display
// (TV) instead of the phone. Settings / Media / Library roots read this to
// pick TV-friendly chrome (bigger top bar, bigger touch targets) instead of
// the phone-sized defaults.
private struct SakuraRenderingOnExternalDisplayKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var sakuraRenderingOnExternalDisplay: Bool {
        get { self[SakuraRenderingOnExternalDisplayKey.self] }
        set { self[SakuraRenderingOnExternalDisplayKey.self] = newValue }
    }
}

private struct ExternalDisplayLibraryRoot: View {
    @Bindable private var theme = ThemeManager.shared
    @State private var appState = AppState.shared
    @State private var gamepad = GamepadNavigation.shared

    var body: some View {
        ZStack {
            AppBackdrop()
                .ignoresSafeArea()
            Group {
                switch appState.currentScreen {
                case .menu:
                    ExternalLibraryShell()
                case .settings:
                    SettingsRootView()
                case .mediaBrowser:
                    MediaBrowserRoot()
                case .playing:
                    Color.black
                        .ignoresSafeArea()
                }
            }
            .id(appState.currentScreen)
            NotificationStack()
                .zIndex(50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ShellKeyboardNavigationHost(
                shouldClaimFirstResponder: gamepad.hasHardwareKeyboard && appState.currentScreen != .playing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .preferredColorScheme(theme.preferredColorScheme)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .environment(\.sakuraRenderingOnExternalDisplay, true)
    }
}

private struct ExternalHandheldHintRoot: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                Image(systemName: "display.2")
                    .font(.system(size: 40, weight: .light))
                Text(SakuraL10n.tr("secondaryScreen.hint.phoneTitle"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(SakuraL10n.tr("secondaryScreen.hint.phoneBody"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
    }
}

private enum GameRenderBinding {
    nonisolated(unsafe) private static var boundView: MetalGameView?

    static func bind(_ view: MetalGameView) {
        boundView = view
        Sakura_IOS_SetGameRenderView(Unmanaged.passUnretained(view).toOpaque())
    }

    static func unbind(_ view: MetalGameView) {
        guard boundView === view else { return }
        boundView = nil
        Sakura_IOS_SetGameRenderView(nil)
    }

    static func isActiveResizeSource(_ view: MetalGameView) -> Bool {
        boundView === view
    }
}

@MainActor
final class RenderHost {
    static let shared = RenderHost()

    let metalView: MetalGameView

    private(set) var isMountedExternally: Bool = false

    private init() {
        let v = MetalGameView()
        v.backgroundColor = .black
        v.clipsToBounds = true
        GameRenderBinding.bind(v)
        self.metalView = v
    }

    func attach(to container: UIView) {
        guard metalView.superview !== container else {
            container.setNeedsLayout()
            container.layoutIfNeeded()
            metalView.setNeedsLayout()
            metalView.layoutIfNeeded()
            metalView.syncCompositorSamplingPathFromCaptureState()
            NotificationCenter.default.post(name: .sakuraUpscaleMultiplierChanged, object: nil)
            return
        }
        metalView.removeFromSuperview()
        metalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: container.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()
        metalView.setNeedsLayout()
        metalView.layoutIfNeeded()
        metalView.syncCompositorSamplingPathFromCaptureState()
        NotificationCenter.default.post(name: .sakuraUpscaleMultiplierChanged, object: nil)
        let externalScreen = container.window?.screen != nil
            && container.window?.screen != UIScreen.main
        isMountedExternally = externalScreen
    }

    func nudgeLayout() {
        guard let parent = metalView.superview else { return }
        parent.setNeedsLayout()
        parent.layoutIfNeeded()
    }

    func markDetachedFromExternal() {
        isMountedExternally = false
    }
}

final class RenderHostContainer: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .black
        self.clipsToBounds = true
        // metal surface is display-only. if we leave interaction on, the
        // container eats every touch that falls in the gap between virtual
        // pad button hit shapes (SwiftUI's ZStack hit-tests top-down and
        // falls through to this UIKit view the moment a button's contentShape
        // misses). That's why taps looked like they did nothing.
        self.isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isUserInteractionEnabled = false
    }
}

/// Two presentation modes (Wii U semantics):
/// - `.handheld`: phone is primary; gameplay + library + chrome live on the
///   phone. If an external display is connected the TV gets a co-play hint
///   (or whatever iOS' native screen mirror provides).
/// - `.tv`: external display is primary; gameplay (when playing) and the
///   AirConsole library shell (when browsing) live on the TV; phone becomes a
///   touch-pad remote.
@MainActor
enum SecondaryGameplayPresentationMode: String {
    case handheld
    case tv
}

@MainActor
final class SecondaryDisplayCoordinator: ObservableObject {
    static let shared = SecondaryDisplayCoordinator()

    private static let udKey = "sakura.airPlay.consolePhoneOnly"
    private static let udModeKey = "sakura.airconsole.mode"

    @Published private(set) var externalRasterSurfaceAvailable: Bool = false
    @Published private(set) var mainDisplayIsBeingSampled: Bool = false
    @Published private(set) var gameOnExternalDisplay: Bool = false

    /// User-controlled "stop streaming" flag: when true while browsing the
    /// library/settings/media, the external display is blanked and the phone
    /// reverts to the normal handheld `LibraryShell`. Auto-cleared when the user
    /// re-enables streaming via the emu top bar's play/airplay button or changes
    /// the presentation mode.
    @Published private(set) var externalBrowsingSuspended: Bool = false

    @MainActor
    func setExternalBrowsingSuspended(_ on: Bool) {
        guard externalBrowsingSuspended != on else { return }
        externalBrowsingSuspended = on
        syncExternalDisplayContent()
    }

    var mode: SecondaryGameplayPresentationMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.udModeKey) {
                // Direct match on the new two-case enum.
                if let m = SecondaryGameplayPresentationMode(rawValue: raw) { return m }
                // Legacy three-mode values: "off"/"duplicate" → handheld;
                // "fullCommit" → tv. Keeps existing user preferences valid
                // after the rename without forcing a re-pick.
                switch raw {
                case "off", "duplicate": return .handheld
                case "fullCommit":       return .tv
                default: break
                }
            }
            if UserDefaults.standard.object(forKey: Self.udKey) != nil {
                let legacyOn = UserDefaults.standard.bool(forKey: Self.udKey)
                return legacyOn ? .tv : .handheld
            }
            return .handheld
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.udModeKey)
            UserDefaults.standard.set(newValue == .tv, forKey: Self.udKey)
            NSLog("[Sakura] secondaryGameplay.mode=\(newValue.rawValue) raster=\(externalRasterSurfaceAvailable ? "yes" : "no") sampled=\(mainDisplayIsBeingSampled ? "yes" : "no") screens=\(UIScreen.screens.count)")
            // changing presentation mode is an explicit user gesture. resume
            // streaming if they'd previously tapped Stop from the phone.
            if externalBrowsingSuspended {
                externalBrowsingSuspended = false
            }
            objectWillChange.send()
            syncExternalDisplayContent()
        }
    }

    var consolePhoneOnlyWants: Bool {
        get { mode == .tv }
        set { mode = newValue ? .tv : .handheld }
    }

    private var externalWindow: UIWindow?
    private var externalGameWindow: UIWindow?
    private weak var externalGameContainer: RenderHostContainer?
    private weak var sceneOwnedWindow: UIWindow?

    static func externalScreen() -> UIScreen? {
        let main = UIScreen.main
        let mb = main.nativeBounds
        let ms = main.nativeScale
        for s in UIScreen.screens {
            guard s !== main else { continue }
            let sb = s.nativeBounds
            if sb.width < 32 || sb.height < 32 { continue }
            if mb.equalTo(sb), ms == s.nativeScale { continue }
            return s
        }
        return nil
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreensChanged()
        }
        NotificationCenter.default.addObserver(
            forName: UIScreen.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreensChanged()
        }
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreensChanged()
        }
        NotificationCenter.default.addObserver(
            forName: .sakuraSecondaryGameplayChromeRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncExternalGameplayHudOnlyIfPlayingExternal()
        }
        handleScreensChanged()
    }

    private func refreshPublishedRasterAndSampling() {
        let raster = (sceneOwnedWindow != nil) || (Self.externalScreen() != nil)
        if externalRasterSurfaceAvailable != raster {
            externalRasterSurfaceAvailable = raster
            // No external surface at all? Don't hold onto the suspension flag
            // so the next connect starts cleanly streaming.
            if !raster, externalBrowsingSuspended {
                externalBrowsingSuspended = false
            }
        }
        let sampled = UIScreen.main.isCaptured
        Sakura_IOS_SetScreenIsCaptured(sampled)
        if mainDisplayIsBeingSampled != sampled {
            mainDisplayIsBeingSampled = sampled
        }
        GamepadNavigation.shared.syncSecondaryRasterShellNavFlag(
            externalRasterSurfaceAvailable: raster
        )
    }

    private func handleScreensChanged() {
        refreshPublishedRasterAndSampling()
        NSLog("[Sakura] screens raster=\(externalRasterSurfaceAvailable ? "yes" : "no") sampled=\(mainDisplayIsBeingSampled ? "yes" : "no") count=\(UIScreen.screens.count)")
        syncExternalDisplayContent()
    }

    func syncExternalDisplayContent() {
        refreshPublishedRasterAndSampling()
        let target: UIScreen? = sceneOwnedWindow?.screen ?? Self.externalScreen()
        NSLog("[Sakura] syncExternal mode=\(mode.rawValue) scene=\(sceneOwnedWindow != nil ? "set" : "nil") target=\(target == nil ? "nil" : "ok") suspended=\(externalBrowsingSuspended ? "yes" : "no")")
        guard let screen = target else {
            reclaimMetalViewToPhone()
            teardownExternalGameWindow()
            teardownExternalLibraryWindow()
            return
        }
        // User-requested "stop streaming" takes priority whenever we're not
        // actively playing. blank the TV and hand the phone back its normal
        // handheld shell.
        if externalBrowsingSuspended, AppState.shared.currentScreen != .playing {
            reclaimMetalViewToPhone()
            teardownExternalGameWindow()
            teardownExternalLibraryWindow()
            return
        }
        switch AppState.shared.currentScreen {
        case .menu, .settings, .mediaBrowser:
            reclaimMetalViewToPhone()
            teardownExternalGameWindow()
            switch mode {
            case .tv:
                // Library / settings / media on the TV; phone is the remote.
                presentExternalLibrary(on: screen)
            case .handheld:
                // Phone owns the chrome; TV gets the Wii U-style co-play
                // hint so others know the session is paired but the player
                // is browsing on the handheld.
                presentExternalHandheldCoPlayHint(on: screen)
            }
        case .playing:
            teardownExternalLibraryWindow()
            switch mode {
            case .handheld:
                // Wii U semantics: gameplay stays on the handheld, TV shows
                // a "someone is playing on the phone" hint card. iOS native
                // screen-mirror, when active, will fill the TV with a real
                // mirror automatically.
                reclaimMetalViewToPhone()
                teardownExternalGameWindow()
                presentExternalHandheldCoPlayHint(on: screen)
            case .tv:
                presentExternalGame(on: screen)
            }
        }
    }

    private func syncExternalGameplayHudOnlyIfPlayingExternal() {
        guard gameOnExternalDisplay else { return }
        guard AppState.shared.currentScreen == .playing else { return }
        guard let screen = sceneOwnedWindow?.screen ?? Self.externalScreen() else { return }
        let targetWindow = externalGameWindow ?? sceneOwnedWindow
        guard let pvc = targetWindow?.rootViewController else { return }
        Self.syncExternalGameplayHud(parent: pvc, presentationScreen: screen)
    }

    private func presentExternalHandheldCoPlayHint(on screen: UIScreen) {
        ensureWindow(on: screen)
        let needsNewRoot = !(externalWindow?.rootViewController is UIHostingController<ExternalHandheldHintRoot>)
        if needsNewRoot {
            let host = UIHostingController(rootView: ExternalHandheldHintRoot())
            host.view.backgroundColor = .black
            externalWindow?.rootViewController = host
        }
        externalWindow?.isHidden = false
    }

    private func ensureWindow(on screen: UIScreen) {
        if let scene = sceneOwnedWindow, externalWindow !== scene {
            externalWindow = scene
            return
        }
        guard externalWindow == nil else { return }
        screen.overscanCompensation = .scale
        let window: UIWindow
        if let ws = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.screen == screen }) {
            window = UIWindow(windowScene: ws)
        } else {
            window = UIWindow(frame: screen.bounds)
            window.screen = screen
        }
        window.backgroundColor = .black
        window.isHidden = false
        externalWindow = window
    }

    private func presentExternalLibrary(on screen: UIScreen) {
        ensureWindow(on: screen)
        let needsNewRoot = !(externalWindow?.rootViewController is UIHostingController<ExternalDisplayLibraryRoot>)
        if needsNewRoot {
            let host = UIHostingController(rootView: ExternalDisplayLibraryRoot())
            host.view.backgroundColor = .black
            externalWindow?.rootViewController = host
        }
        externalWindow?.isHidden = false
    }

    private func teardownExternalLibraryWindow() {
        if externalWindow === sceneOwnedWindow {
            externalWindow?.rootViewController = nil
            externalWindow = nil
            return
        }
        externalWindow?.isHidden = true
        externalWindow?.rootViewController = nil
        externalWindow = nil
    }

    static let externalGameplayHudRestorationID = "sakura.externalGameplayOSD"

    static func detachExternalGameplayHud(from parent: UIViewController?) {
        guard let parent else { return }
        for child in parent.children where child.restorationIdentifier == externalGameplayHudRestorationID {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }

    static func syncExternalGameplayHud(parent: UIViewController, presentationScreen: UIScreen) {
        detachExternalGameplayHud(from: parent)
        guard SettingsStore.shared.hudEnabled else { return }
        let hud = UIHostingController(rootView: OSDGameplayOverlay(presentationScreen: presentationScreen))
        hud.restorationIdentifier = externalGameplayHudRestorationID
        hud.view.backgroundColor = .clear
        parent.addChild(hud)
        parent.view.addSubview(hud.view)
        hud.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hud.view.topAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.topAnchor, constant: 10),
            hud.view.trailingAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        hud.didMove(toParent: parent)
    }

    private func presentExternalGame(on screen: UIScreen) {
        let targetWindow: UIWindow
        if let scene = sceneOwnedWindow {
            targetWindow = scene
        } else if let existing = externalGameWindow {
            targetWindow = existing
        } else {
            screen.overscanCompensation = .scale
            let window: UIWindow
            if let ws = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.screen == screen }) {
                window = UIWindow(windowScene: ws)
            } else {
                window = UIWindow(frame: screen.bounds)
                window.screen = screen
            }
            window.backgroundColor = .black
            targetWindow = window
        }

        let isOurs = (externalGameContainer != nil)
            && (externalGameContainer?.window === targetWindow)
        if !isOurs {
            let container = RenderHostContainer(frame: .zero)
            container.translatesAutoresizingMaskIntoConstraints = false
            let vc = UIViewController()
            vc.view.backgroundColor = .black
            vc.view.addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: vc.view.topAnchor),
                container.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            ])
            targetWindow.rootViewController = vc
            externalGameContainer = container
        }
        externalGameWindow = targetWindow
        targetWindow.isHidden = false

        guard let container = externalGameContainer else { return }
        RenderHost.shared.attach(to: container)
        if let pvc = targetWindow.rootViewController {
            Self.syncExternalGameplayHud(parent: pvc, presentationScreen: screen)
        }
        NSLog("[Sakura] presentExternalGame ext=\(container.window?.screen != UIScreen.main ? "yes" : "no")")
        if !gameOnExternalDisplay {
            gameOnExternalDisplay = true
            objectWillChange.send()
        }
    }

    private func reclaimMetalViewToPhone() {
        guard gameOnExternalDisplay || RenderHost.shared.isMountedExternally else {
            RenderHost.shared.markDetachedFromExternal()
            return
        }
        let mv = RenderHost.shared.metalView
        mv.removeFromSuperview()
        mv.translatesAutoresizingMaskIntoConstraints = false
        RenderHost.shared.markDetachedFromExternal()
        if gameOnExternalDisplay {
            gameOnExternalDisplay = false
            objectWillChange.send()
        }
    }

    private func teardownExternalGameWindow() {
        if let pvc = externalGameWindow?.rootViewController {
            Self.detachExternalGameplayHud(from: pvc)
        }
        externalGameContainer = nil
        if externalGameWindow === sceneOwnedWindow {
            externalGameWindow?.rootViewController = nil
            externalGameWindow = nil
            return
        }
        externalGameWindow?.isHidden = true
        externalGameWindow?.rootViewController = nil
        externalGameWindow = nil
    }

    func adoptExternalSceneWindow(_ window: UIWindow) {
        sceneOwnedWindow = window
        refreshPublishedRasterAndSampling()
        syncExternalDisplayContent()
    }

    func releaseExternalSceneWindow(_ window: UIWindow?) {
        reclaimMetalViewToPhone()
        teardownExternalGameWindow()
        teardownExternalLibraryWindow()
        if sceneOwnedWindow === window || window == nil {
            sceneOwnedWindow = nil
        }
        refreshPublishedRasterAndSampling()
    }
}

final class MetalGameView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private nonisolated(unsafe) var gpuCadenceLink: CADisplayLink?
    private nonisolated(unsafe) var gamepadInputLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        if let metal = self.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.backgroundColor = UIColor.black.cgColor
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpscaleChanged),
            name: .sakuraUpscaleMultiplierChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGpuCadenceSettingChanged),
            name: .sakuraMainThreadMetalPresentChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpscaleChanged),
            name: .sakuraNativeScaleDrawableChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCompositorPathChanged),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCompositorPathChanged),
            name: UIScreen.didConnectNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCompositorPathChanged),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )
        if #available(iOS 17.0, *) {
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self,
                UITraitPreferredContentSizeCategory.self,
                UITraitHorizontalSizeClass.self,
                UITraitVerticalSizeClass.self,
            ]) { (self: MetalGameView, _: UITraitCollection) in
                self.refreshGameplayDisplayLinkFPS()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        gpuCadenceLink?.invalidate()
        gamepadInputLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        gpuCadenceLink?.invalidate()
        gpuCadenceLink = nil
        gamepadInputLink?.invalidate()
        gamepadInputLink = nil
        if window != nil {
            configureGamepadInputDisplayLink()
            configureGpuCadenceDisplayLink()
            refreshGameplayDisplayLinkFPS()
        }
    }

    private func preferredGameDisplayHz() -> Float {
        Float(window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond)
    }

    private func applyCadenceDuplicateRate(to link: CADisplayLink) {
        let hz = preferredGameDisplayHz()
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: hz, preferred: hz)
    }

    private func refreshGameplayDisplayLinkFPS() {
        guard window != nil else { return }
        if let link = gpuCadenceLink {
            applyCadenceDuplicateRate(to: link)
        }
        if let link = gamepadInputLink {
            applyCadenceDuplicateRate(to: link)
        }
    }

    @objc private func handleUpscaleChanged() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    @objc private func handleGpuCadenceSettingChanged() {
        gpuCadenceLink?.invalidate()
        gpuCadenceLink = nil
        if window != nil {
            configureGpuCadenceDisplayLink()
        }
    }

    @objc private func handleCompositorPathChanged() {
        syncCompositorSamplingPathFromCaptureState()
    }

    fileprivate func syncCompositorSamplingPathFromCaptureState() {
        Sakura_IOS_SetScreenIsCaptured(UIScreen.main.isCaptured)
        applyCompositorSamplingLayerTweaks()
        setNeedsLayout()
        layoutIfNeeded()
        setNeedsDisplay()
        NotificationCenter.default.post(name: .sakuraUpscaleMultiplierChanged, object: nil)
    }

    @objc private func refreshGamepadInputCache() {
        SakuraBridge.refreshPhysicalGamepadInputCache()
    }

    @objc private func pumpGpuCadence() {
        SakuraBridge.gpuCadencePump()
    }

    private func configureGamepadInputDisplayLink() {
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshGamepadInputCache))
        applyCadenceDuplicateRate(to: link)
        link.add(to: .main, forMode: .common)
        gamepadInputLink = link
        refreshGamepadInputCache()
    }

    private func configureGpuCadenceDisplayLink() {
        guard window != nil else { return }
        guard SettingsStore.shared.mainThreadMetalPresentEnabled else { return }
        let link = CADisplayLink(target: self, selector: #selector(pumpGpuCadence))
        applyCadenceDuplicateRate(to: link)
        link.add(to: .main, forMode: .default)
        gpuCadenceLink = link
    }

    private func applyCompositorSamplingLayerTweaks() {
        guard let mtl = layer as? CAMetalLayer else { return }
        mtl.framebufferOnly = false
        mtl.presentsWithTransaction = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCompositorSamplingLayerTweaks()

        if let mtlLayer = self.layer as? CAMetalLayer {
            mtlLayer.contentsGravity = .resize
            if mtlLayer.frame != bounds {
                mtlLayer.frame = bounds
            }
        }

        guard GameRenderBinding.isActiveResizeSource(self) else { return }
        let scale = SettingsStore.shared.nativeScaleMetalDrawable
            ? max(1.0, CGFloat(window?.screen.scale ?? UIScreen.main.scale))
            : max(1.0, min(CGFloat(SettingsStore.shared.upscaleMultiplier), 16.0))
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))
        if let mtlLayer = self.layer as? CAMetalLayer {
            if mtlLayer.contentsScale != scale {
                mtlLayer.contentsScale = scale
            }
            let newSize = CGSize(width: CGFloat(w), height: CGFloat(h))
            if mtlLayer.drawableSize != newSize {
                mtlLayer.drawableSize = newSize
            }
        }
        Sakura_IOS_NotifyDisplayResize(Int32(w), Int32(h), Float(scale))
    }
}

struct GameMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = RenderHostContainer(frame: .zero)
        DispatchQueue.main.async { [weak container] in
            guard let container else { return }
            RenderHost.shared.attach(to: container)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let container = uiView as? RenderHostContainer else { return }
        if RenderHost.shared.metalView.superview !== container {
            RenderHost.shared.attach(to: container)
        }
    }
}
