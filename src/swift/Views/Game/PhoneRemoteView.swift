// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct PhoneRemoteView: View {
    @State private var theme = ThemeManager.shared
    @State private var appState = AppState.shared
    @ObservedObject private var secondaryDisplay = SecondaryDisplayCoordinator.shared
    @State private var isEditMode = false
    @State private var selectedGroupID = "dpad"

    private var phoneChromeTitleKey: String {
        switch appState.currentScreen {
        case .settings:
            return SakuraL10n.tr("secondaryScreen.phone.settingsOnExternal")
        case .mediaBrowser:
            return SakuraL10n.tr("secondaryScreen.phone.mediaOnExternal")
        case .menu, .playing:
            return SakuraL10n.tr("secondaryScreen.phone.libraryOnExternal")
        }
    }

    var body: some View {
        SakuraPhoneTouchPadShell(
            isEditMode: $isEditMode,
            selectedGroupID: $selectedGroupID,
            padVisible: true
        ) { sw, sh in
            VStack(spacing: 14) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                    .symbolRenderingMode(.monochrome)
                Text(phoneChromeTitleKey)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                // Only ever shown in TV mode now (the only mode where the
                // phone gives up its primary chrome). Handheld keeps the
                // normal LibraryShell.
                Text(SakuraL10n.tr("secondaryScreen.phone.hintTouch"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(width: sw, height: sh)
            .background(Color.black)
        }
        .preferredColorScheme(theme.preferredColorScheme)
        .statusBarHidden()
        .modifier(HidePersistentOverlaysModifier())
        .overlay(alignment: .top) {
            PhoneRemoteTopStrip()
        }
    }
}

// single floating capsule. matches the in-game emu top bar's rightmost
// cluster (same background + stroke) so it reads as part of the emu chrome,
// not a duplicate library header. only shows the Stop-TV button because
// section switching is already handled by L1/R1 on the virtual pad.
private struct PhoneRemoteTopStrip: View {
    @State private var theme = ThemeManager.shared

    private var capsuleBackground: AnyShapeStyle {
        if theme.inGameMenuUsesLiteChrome {
            return AnyShapeStyle(Color.black.opacity(theme.inGameTopBarOpacity))
        }
        if theme.materialsReduced {
            return AnyShapeStyle(Color.black.opacity(min(1, max(theme.inGameTopBarOpacity, 0.78))))
        }
        return AnyShapeStyle(Material.ultraThin)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                SecondaryDisplayCoordinator.shared.setExternalBrowsingSuspended(true)
                SFXManager.shared.play(.back)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                    Text(SakuraL10n.tr("secondaryScreen.phone.stopStreaming"))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(theme.topBarTextColor())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(capsuleBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SakuraL10n.tr("secondaryScreen.phone.stopStreaming"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}
