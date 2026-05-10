// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct TopBarMusicBar: View {
    @State private var player = MusicPlayer.shared
    @State private var theme = ThemeManager.shared

    var body: some View {
        if player.playlist.isEmpty {
            EmptyView()
        } else {
            Button {
                player.toggleFromUser()
            } label: {
                ZStack {
                    Color.clear
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(theme.topBarCaptionColor().opacity(player.isPlaying ? 0.25 : 0.15))
                                .frame(height: 2)

                            Capsule(style: .continuous)
                                .fill(theme.topBarAccentColor().opacity(player.isPlaying ? 1.0 : 0.55))
                                .frame(
                                    width: max(0, CGFloat(player.progress) * geo.size.width),
                                    height: 2
                                )
                        }
                        .frame(height: 2)
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)

                    if !player.isPlaying {
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(theme.topBarCaptionColor().opacity(0.7))
                            Spacer()
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? SakuraL10n.tr("music.miniBar.pauseA11y") : SakuraL10n.tr("music.miniBar.playA11y"))
        }
    }
}
