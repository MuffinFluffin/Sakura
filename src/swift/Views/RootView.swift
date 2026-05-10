// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var secondaryDisplay = SecondaryDisplayCoordinator.shared
    @State private var appState = AppState.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var fileImporter = FileImportHandler.shared
    @State private var theme = ThemeManager.shared
    @State private var splashVisible = true
    @AppStorage("sakura.onboarding.completed") private var onboardingCompleted = false
    @AppStorage(AppLocale.appStorageKey) private var localeOverrideRaw = ""
    @State private var showOnboarding = false
    @State private var announcements = AnnouncementManager.shared
    @State private var notifications = SakuraNotificationCenter.shared
    @State private var ratingPrompt = RatingPromptCoordinator.shared

    // TV mode + external screen connected: library/settings/media render on
    // the TV and the phone hosts the touch-pad remote (PhoneRemoteView).
    // in Handheld mode the phone keeps its normal chrome (Wii U semantics:
    // the gamepad screen is the primary display) regardless of whether a TV
    // is attached. externalBrowsingSuspended (Stop-TV button) also forces
    // the phone back to the local shell.
    private var phoneShowsRemoteChromeWhileBrowsing: Bool {
        secondaryDisplay.mode == .tv
            && secondaryDisplay.externalRasterSurfaceAvailable
            && !secondaryDisplay.externalBrowsingSuspended
            && appState.currentScreen != .playing
    }

    var body: some View {
        ZStack {
            if appState.currentScreen != .playing {
                AppBackdrop()
                    .ignoresSafeArea()
            }

            switch appState.currentScreen {
            case .menu:
                Group {
                    if phoneShowsRemoteChromeWhileBrowsing {
                        PhoneRemoteView()
                    } else {
                        LibraryShell()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .settings:
                Group {
                    if phoneShowsRemoteChromeWhileBrowsing {
                        PhoneRemoteView()
                    } else {
                        SettingsRootView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .mediaBrowser:
                Group {
                    if phoneShowsRemoteChromeWhileBrowsing {
                        PhoneRemoteView()
                    } else {
                        MediaBrowserRoot()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .playing:
                EmulationView()
            }

            // "Resume on TV" only makes sense in TV mode. Handheld mode
            // never hands its chrome to the TV, nothing to resume.
            if secondaryDisplay.mode == .tv
                && secondaryDisplay.externalBrowsingSuspended
                && secondaryDisplay.externalRasterSurfaceAvailable
                && appState.currentScreen != .playing
            {
                VStack {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button {
                            secondaryDisplay.setExternalBrowsingSuspended(false)
                            SFXManager.shared.play(.confirm)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "airplayvideo")
                                    .font(.system(size: 14, weight: .bold))
                                Text(SakuraL10n.tr("secondaryScreen.phone.resumeStreaming"))
                                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(theme.accentColor().opacity(0.88)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(true)
                .zIndex(90)
            }

            NotificationStack()
                .zIndex(100)

            if splashVisible {
                SplashView {
                    splashVisible = false
                    if !onboardingCompleted {
                        AppLocale.seedLocaleFromSystemWhenUnsetAndOnboardingIncomplete(onboardingCompleted: onboardingCompleted)
                        showOnboarding = true
                    }
                }
                .zIndex(200)
                .transition(.opacity)
            }

            if showOnboarding {
                OnboardingView {
                    MusicPlayer.shared.stopOnboardingMusic()
                    MusicPlayer.shared.refreshPlaylist()
                    MusicPlayer.shared.autoResumeIfStickyAndLibraryVisible()
                    withAnimation(theme.shellOverlayDismissAnimation) {
                        showOnboarding = false
                    }
                    onboardingCompleted = true
                    announcements.fetchAndProcess()
                }
                .zIndex(300)
                .transition(.opacity)
            }

            if let active = announcements.activeFullscreen {
                AnnouncementFullscreenView(announcement: active) {
                    withAnimation(theme.shellOverlayDismissAnimation) {
                        announcements.dismissFullscreen()
                    }
                }
                .zIndex(400)
                .transition(.opacity)
            }

            if let activeCard = notifications.activeFullscreenCard {
                CardNotificationFullscreenView(card: activeCard) {
                    withAnimation(theme.shellOverlayDismissAnimation) {
                        notifications.dismissFullscreenCard()
                    }
                }
                .zIndex(410)
                .transition(.opacity)
            }

            if ratingPrompt.isPromptVisible {
                RatingPromptView(
                    onYes: { ratingPrompt.userTappedYes() },
                    onNo: { ratingPrompt.userTappedNo() }
                )
                .zIndex(420)
                .transition(.opacity)
            }
        }
        .background {
            ShellKeyboardNavigationHost(
                shouldClaimFirstResponder: gamepad.hasHardwareKeyboard && appState.currentScreen != .playing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .id(localeOverrideRaw)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.locale, AppLocale.resolvedLocale(rawOverride: localeOverrideRaw))
        .preferredColorScheme(theme.preferredColorScheme)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            SecondaryDisplayCoordinator.shared.syncExternalDisplayContent()
            SakuraL10n.loadIfNeeded()
            TipPurchase.shared.startListeningForTransactionUpdates()
            ControllerEvents.shared.startIfNeeded()
            ControllerPortAssigner.shared.start()
            ControllerRumbleManager.shared.startIfNeeded()
            SFXManager.shared.bootstrapIfNeeded()
            AudioSession.shared.ensureActiveForUIAudio()
            if onboardingCompleted {
                announcements.fetchAndProcess()
            }
            Task {
                let newCount = await MusicCatalog.refreshRemoteCatalog()
                if newCount > 0 {
                    await MainActor.run {
                        MusicPlayer.shared.refreshPlaylist()
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, onboardingCompleted {
                announcements.fetchAndProcess()
            }
            if phase == .active {
                gamepad.syncHardwareKeyboardFromSystem()
            }
        }
        .onChange(of: localeOverrideRaw) { _, _ in
            SakuraL10n.loadIfNeeded()
        }
        .onOpenURL { url in
            fileImporter.handleURL(url)
        }
        .alert(SakuraL10n.tr("ui.dialog.fileImportTitle"), isPresented: $fileImporter.showImportAlert) {
            Button(SakuraL10n.tr("common.ok")) {}
        } message: {
            Text(fileImporter.lastImportMessage ?? "")
        }
    }
}
