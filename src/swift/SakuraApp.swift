// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

@main
struct SakuraApp: App {
    @UIApplicationDelegateAdaptor(SakuraUIApplicationDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var pausedEmulationForScenePhase = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    ApplyPreferredContentSizeCategoryBaseline()
                    let preventSleep = SettingsStore.shared.emuMenuPreventScreenSleep
                    UIApplication.shared.isIdleTimerDisabled = preventSleep
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        if pausedEmulationForScenePhase, SakuraBridge.isEmulationRunning() {
                            SakuraBridge.setEmulationPaused(false)
                        }
                        pausedEmulationForScenePhase = false
                    case .inactive:
                        if SakuraBridge.isEmulationRunning(), !SakuraBridge.isEmulationPaused() {
                            SakuraBridge.setEmulationPaused(true)
                            pausedEmulationForScenePhase = true
                        }
                        SakuraBridge.saveNVRAM()
                        SakuraBridge.flushINIWritesSynchronously()
                    case .background:
                        if SakuraBridge.isEmulationRunning(), !SakuraBridge.isEmulationPaused() {
                            SakuraBridge.setEmulationPaused(true)
                            pausedEmulationForScenePhase = true
                        }
                        SakuraBridge.saveAllState()
                        SakuraBridge.flushINIWritesSynchronously()
                    default:
                        break
                    }
                }
        }
    }
}

@MainActor
private func ApplyPreferredContentSizeCategoryBaseline() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        scene.traitOverrides.preferredContentSizeCategory = .large
    }
}

final class SakuraUIApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Sakura_IOS_EarlyInit()
        let onboardingDone = UserDefaults.standard.bool(forKey: "sakura.onboarding.completed")
        AppLocale.seedLocaleFromSystemWhenUnsetAndOnboardingIncomplete(onboardingCompleted: onboardingDone)
        SakuraL10n.loadIfNeeded()
        Sakura_IOS_OnSceneReady()
        SettingsStore.shared.reload()
        prewarmCherryBlossomSplashVideo()
        Task { @MainActor in
            ApplyPreferredContentSizeCategoryBaseline()
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            ApplyPreferredContentSizeCategoryBaseline()
        }
    }

    /// Kick off AVPlayer asset loading for the splash video before SwiftUI mounts the splash,
    /// so that by the time SplashView appears the cherry blossom motion is already rendering.
    private func prewarmCherryBlossomSplashVideo() {
        let stem = ThemeManager.cherryBlossomsBackdrop
        guard let url = Bundle.main.url(forResource: stem, withExtension: "mp4")
            ?? Bundle.main.url(forResource: stem, withExtension: "mov") else { return }
        DispatchQueue.main.async {
            SplashVideoController.shared.prewarm(url: url)
        }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }
}
