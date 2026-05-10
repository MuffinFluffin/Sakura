// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

// bottom action bar for the AirConsole library. mirrors the handheld bar
// but renders with TV-friendly spacing and always shows symbols (no compact mode).
struct ExternalActionBar: View {
    let game: GameItem?
    var onPlay: (GameItem) -> Void
    var onToggleFavorite: (GameItem) -> Void
    var onToggleFastBoot: () -> Void
    var onImport: () -> Void

    @State private var theme = ThemeManager.shared
    @State private var settings = SettingsStore.shared
    @State private var gamepad = GamepadNavigation.shared

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            PSActionBadge(
                systemName: "l1.button.roundedbottom.horizontal",
                psIcon: nil,
                psFallback: nil,
                shoulderSymbol: "l1.button.roundedbottom.horizontal",
                shoulderSymbolSecond: "r1.button.roundedbottom.horizontal",
                title: SakuraL10n.tr("library.hint.pages"),
                tint: theme.color(forKey: "yellow"),
                libraryFooterCompact: false,
                tvMode: true
            )

            if let game {
                PSActionBadge(
                    systemName: "play.fill",
                    psIcon: "cross",
                    psFallback: gamepad.confirmLabel,
                    title: SakuraL10n.tr("library.bottom.playCaps"),
                    tint: theme.color(forKey: "blue"),
                    libraryFooterCompact: false,
                    tvMode: true
                ) {
                    onPlay(game)
                }

                PSActionBadge(
                    systemName: game.isFavorite ? "heart.fill" : "heart",
                    psIcon: "circle",
                    psFallback: gamepad.backLabel,
                    title: game.isFavorite
                        ? SakuraL10n.tr("library.context.unfavorite")
                        : SakuraL10n.tr("library.bottom.favorite"),
                    tint: theme.color(forKey: "red"),
                    libraryFooterCompact: false,
                    tvMode: true
                ) {
                    onToggleFavorite(game)
                }

                PSActionBadge(
                    systemName: settings.fastBoot ? "bolt.fill" : "bolt.slash",
                    psIcon: "triangle",
                    psFallback: gamepad.tertiaryLabel,
                    title: settings.fastBoot
                        ? SakuraL10n.tr("library.bottom.fastBoot")
                        : SakuraL10n.tr("library.bottom.fullBoot"),
                    tint: theme.color(forKey: "green"),
                    libraryFooterCompact: false,
                    tvMode: true
                ) {
                    onToggleFastBoot()
                }
            }

            PSActionBadge(
                systemName: "line.3.horizontal",
                psIcon: nil,
                psFallback: nil,
                title: SakuraL10n.tr("library.bottom.import"),
                tint: theme.glassTextPrimary(.dark),
                libraryFooterCompact: false,
                tvMode: true
            ) {
                onImport()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.38))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        )
    }
}
